#!/bin/bash

audit_rules_file="/etc/audit/rules.d/audit.rules"

audit_rule() {
	echo $no_rule
	echo "	add '$add_rule' to audit rules";
	echo "	adding..."
	echo $add_rule >> $audit_rules_file
	echo "	restarting auditd daemon"
	systemctl restart auditd
	echo "	run this script one more time"
	exit
}
audit_file() {
        if [ -f $check_file ]; then
                if ! auditctl -l | grep -q $check_file; then
                        no_rule="no audit rules for $check_file";
                        add_rule="-w $check_file -k docker";
			echo $no_rule
#                        audit_rule
                fi
        else
                echo "no such file: $check_file";
        fi
}

docker_mount_point=`docker info -f '{{ .DockerRootDir }}'"\s"`
if ! grep -q $docker_mount_point /proc/mounts; then
	mountpoint -- "$(docker info -f '{{ .DockerRootDir }}')"
	echo "	with new installation create separate partition"
	#exit
fi

docker_group_users=`getent group docker | awk -F ':' '{print $4}'`
if [ "$docker_group_users" != "" ] && [ "$docker_group_users" != "root" ]; then
	echo "untrusted user in docker group"
fi

if ! command -v auditctl &> /dev/null; then
	echo "no such command auditctl"
	echo "	check if auditd package is installled"
else
	if ! auditctl -l | grep -q /usr/bin/dockerd; then
		no_rule="no audit rules for docker daemon"
		add_rule="-w /usr/bin/dockerd -k docker"
		audit_rule
	fi
	if ! auditctl -l | grep -q /run/containerd; then
		no_rule="no audit rules for /run/containerd directory"
		add_rule="-a exit,always -F path=/run/containerd -F perm=war -k docker"
		audit_rule
	fi
	docker_main_dir=`docker info -f '{{ .DockerRootDir }}'`
	if ! auditctl -l | grep -q $docker_main_dir; then
		no_rule="no audit rules for $docker_main_dir";
		add_rule="-a exit,always -F path=$docker_main_dir -F perm=war -k docker"
		audit_rule
	fi
	if ! auditctl -l | grep -q /etc/docker; then
		no_rule="no audit rules for /etc/docker directory";
		add_rule="-w /etc/docker -k docker";
		audit_rule
	fi
	docker_service_file_path=`systemctl show -p FragmentPath docker.service | awk -F '=' '{print $2}'`;
	if [ "$docker_service_file_path" != "" ]; then
		if ! auditctl -l | grep -q $docker_service_file_path; then
			no_rule="no audit rules for $docker_service_file_path";
			add_rule="-w $docker_service_file_path -k docker";
			audit_rule
		fi
	fi
	containerd_sock=`systemctl status docker | grep containerd.sock | awk -F '=' '{print $NF}'`;
	if [ "$containerd_sock" != "" ]; then
		if ! auditctl -l | grep -q $containerd_sock; then
			no_rule="no audit rules for $containerd_sock";
			add_rule="-w $containerd_sock -k docker";
			audit_rule
		fi
	fi
	docker_socket_file_path=`systemctl show -p FragmentPath docker.socket | awk -F '=' '{print $2}'`;
	if [ "$docker_socket_file_path" != "" ]; then
		docker_listen_stream=`grep ListenStream $docker_socket_file_path | awk -F '=' '{print $2}'`
		if [ "$docker_listen_stream" != "" ]; then
			if ! auditctl -l | grep -q docker.sock; then
				no_rule="no audit rules for $docker_listen_stream"
				add_rule="-w $docker_listen_stream -k docker"
				audit_rule
			fi
		else
			echo "unable to find docker.sock file"
		fi
	fi
	check_file="/etc/default/docker"
	audit_file
	check_file="/etc/docker/daemon.json"
	audit_file
	check_file="/etc/containerd/config.toml"
	audit_file
	check_file="/etc/sysconfig/docker"
	audit_file
	check_file="/usr/bin/containerd"
	audit_file
	check_file="/usr/bin/containerd-shim"
	audit_file
	check_file="/usr/bin/containerd-shim-runc-v1"
	audit_file
	check_file="/usr/bin/containerd-shim-runc-v2"
	audit_file
	check_file="/usr/bin/runc"
	audit_file
fi
docker_user_owner=`ps -fe | grep 'dockerd' | awk '{print $1}' | grep -v 'root\|grep'`
if [ "$docker_user_owner" == "" ]; then
	echo "docker daemon is running as root. If possible run as other user: https://docs.docker.com/engine/security/rootless/"
fi

for i in $(docker network ls --quiet); do
	docker_options=`docker network inspect --format '{{ json .Options }}' $i`
	if [ "$docker_options" != "" ] && [ "$docker_options" != '{}' ]; then
		icc_status=`echo $docker_options | awk -F 'enable_icc' '{print $2}' | awk -F ',' '{print $1}' | sed 's/[:"]//g'`
		if [ "$icc_status" == "true" ]; then
			echo "traffic is not restricted between containers (docker inspect $i) on the default bridge"
			echo "	add --icc=false to docker daemon. Usually it is located /lib/systemd/system/docker.service"
		fi
	fi
done

dockerd_main=`pidof dockerd`
docker_process=`ps f -o cmd --no-headers $dockerd_main`
if [ "$docker_process" != "" ]; then
	log_level=`echo $docker_process | awk -F '--log-level=' '{print $2}' | awk -F ' ' '{print $1}'`
	if [ "$log_level" != "info" ]; then
		echo "dockerd daemon logging is set to: $log_level";
	fi
fi

docker_process=`ps f -o cmd --no-headers $dockerd_main`
if [ "$docker_process" != "" ]; then
        log_level=`echo $docker_process | awk -F '--iptables=' '{print $2}' | awk -F ' ' '{print $1}'`
        if [ "$log_level" == "false" ]; then
                echo "change docker daemon iptables set to true";
        fi
fi

is_any_unsecure_repo=`docker info --format 'Insecure Registries: {{.RegistryConfig.InsecureRegistryCIDRs}}' | awk -F 'Insecure Registries: ' '{print $2}'`
if [ "$is_any_unsecure_repo" != '[127.0.0.0/8]' ]; then
	echo "There is unsecure repo $is_any_unsecure_repo";
fi	

