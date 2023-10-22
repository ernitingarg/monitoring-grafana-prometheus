#!/bin/bash

PARENT_DIR=$(dirname $BASH_EXE_PATH)
ROOT_DIR=$(dirname $PARENT_DIR)
PACKAGE_DIR="$ROOT_DIR/_package"
PACKAGE_MONITORING_DIR="$PACKAGE_DIR/monitoring"
NEWLINE=$'\n'
TAB=$'\t'
TWO_SPACES=$'  '
SIX_SPACES=$'      '
EIGTH_SPACES=$'        '

# load environment file
source $PARENT_DIR/templates/.env

EMPTY_DIR=(
	"prometheus"
	"prometheus/rules"
	"docker"
	"host"
	"grafana"
	"blackbox_exporter"
	"loki"
	"alertmanager"
)

GENERAL_MANDATORY_PARAMS=(
	"ENV"
	"PROJECT_NAME"
	"MOUNT_DIR"
	"MONITORING_IP_ADDRESS"
	"MONITORING_RESOURCE_NAME"
	"SLACK_WEB_HOOK_URL"
	"SLACK_CHANNEL_NAME"
)

HOST_MANDATORY_PARAMS=(
	"IP_ADDRESS"
	"RESOURCE_NAME"
)

WEB_MANDATORY_PARAMS=(
	"URL"
	"RESOURCE_NAME"
)

function validation() {
	if [[ -z $HOST_COUNT && -z $WEB_COUNT ]] || [[ $HOST_COUNT -eq 0 && $WEB_COUNT -eq 0 ]]; then
		echo "'HOST_COUNT' & 'WEB_COUNT' both parameters have value null or 0. Atleast one parameter is required to be configured."
		exit 1
	fi

	HAS_ERROR=false
	for param in "${GENERAL_MANDATORY_PARAMS[@]}"; do
		if [[ -z ${!param} ]]; then
			echo "For parameter '${param}', please assign the value."
			HAS_ERROR=true
		fi
	done

	index=0
	while [ $index -le $((HOST_COUNT - 1)) ]; do
		for param in "${HOST_MANDATORY_PARAMS[@]}"; do
			HOST_PARAM=HOST${index}_${param}
			if [[ -z ${!HOST_PARAM} ]]; then
				echo "For parameter '${HOST_PARAM}', please assign the value."
				HAS_ERROR=true
			else
				__validate_if_host_ip_address_has_correct_format $param $HOST_PARAM
			fi
		done
		((index++))
	done

	index=0
	while [ $index -le $((WEB_COUNT - 1)) ]; do
		for param in "${WEB_MANDATORY_PARAMS[@]}"; do
			WEB_PARAM=WEB${index}_${param}
			if [[ -z ${!WEB_PARAM} ]]; then
				echo "For parameter '${WEB_PARAM}', please assign the value."
				HAS_ERROR=true
			fi
		done
		((index++))
	done

	if $HAS_ERROR; then
		echo "please assign the value(s) for above parameters in file '$PARENT_DIR/templates/.env'"
		exit 1
	fi
}

function make_empty_dir() {
	rm -rf $PACKAGE_DIR

	for path in "${EMPTY_DIR[@]}"; do
		mkdir -p $PACKAGE_MONITORING_DIR/$path
	done
}

function prepare_files_from_template() {
	export MSYS_NO_PATHCONV=1

	HERE='{{ if eq .Labels.severity "critical" }}<!here>{{ end }}'

	# copy/export configuration files
	cp -r $PARENT_DIR/templates/grafana $PACKAGE_MONITORING_DIR
	cp -r $PARENT_DIR/templates/loki $PACKAGE_MONITORING_DIR
	cp $PARENT_DIR/templates/blackbox_exporter/blackbox.yml $PACKAGE_MONITORING_DIR/blackbox_exporter
	MONITORING_IP_ADDRESS=$MONITORING_IP_ADDRESS envsubst <$PARENT_DIR/templates/grafana/grafana.env >$PACKAGE_MONITORING_DIR/grafana/grafana.env

	# copy rules files
	cp -r $PARENT_DIR/templates/prometheus/rules/* $PACKAGE_MONITORING_DIR/prometheus/rules

	# copy alertmanager file
	SLACK_WEB_HOOK_URL=$SLACK_WEB_HOOK_URL SLACK_CHANNEL_NAME=$SLACK_CHANNEL_NAME HERE=$HERE envsubst <$PARENT_DIR/templates/alertmanager/alertmanager.yml >$PACKAGE_MONITORING_DIR/alertmanager/alertmanager.yml

	# copy dashboards
	cp -r $PARENT_DIR/dashboards/* $PACKAGE_MONITORING_DIR/grafana/provisioning/dashboards

	# copy docker/host files
	MOUNT_DIR=$MOUNT_DIR envsubst <$PARENT_DIR/templates/docker/docker-compose.yml >$PACKAGE_MONITORING_DIR/docker/docker-compose.yml
	MOUNT_DIR=$MOUNT_DIR envsubst <$PARENT_DIR/templates/host/resource-monitoring.service >$PACKAGE_MONITORING_DIR/host/resource-monitoring.service

	__prepare_prometheus_file
}

function zip_deployment_folders() {
	7z a -tzip $PACKAGE_MONITORING_DIR ./$PACKAGE_MONITORING_DIR
}

__target_template() {
	TARGET=${NEWLINE}${SIX_SPACES}
	TARGET+="- targets: ['$1']"
	TARGET+="${NEWLINE}${EIGTH_SPACES}labels:"
	TARGET+="${NEWLINE}${EIGTH_SPACES}${TWO_SPACES}target_env: '${PROJECT_NAME,,}'"
	TARGET+="${NEWLINE}${EIGTH_SPACES}${TWO_SPACES}target_resource_name: '$2'"
	echo "$TARGET"
}

__prepare_prometheus_file() {
	TARGET_NODE_EXPORTER_LIST=""
	TARGET_CADVISOR_LIST=""
	TARGET_PROMTAIL_LIST=""
	TARGET_BLACKBOX_HTTPS_PROBE_LIST="" #[https_2xx -> https requests require ssl validation]
	TARGET_BLACKBOX_HTTP_PROBE_LIST=""  #[http_2xx -> http or https without ssl]

	index=0
	while [ $index -le $((HOST_COUNT - 1)) ]; do
		IP_ADDRESS=HOST${index}_IP_ADDRESS
		RESOURCE_NAME=HOST${index}_RESOURCE_NAME

		TARGET_NODE_EXPORTER=$(__target_template ${!IP_ADDRESS}:9100 ${!RESOURCE_NAME,,})
		TARGET_NODE_EXPORTER_LIST+="${TARGET_NODE_EXPORTER}${NEWLINE}"

		TARGET_CADVISOR=$(__target_template ${!IP_ADDRESS}:8080 ${!RESOURCE_NAME,,})
		TARGET_CADVISOR_LIST+="${TARGET_CADVISOR}${NEWLINE}"

		TARGET_PROMTAIL=$(__target_template ${!IP_ADDRESS}:9080 ${!RESOURCE_NAME,,})
		TARGET_PROMTAIL_LIST+="${TARGET_PROMTAIL}${NEWLINE}"

		((index++))
	done

	index=0
	while [ $index -le $((WEB_COUNT - 1)) ]; do
		URL=WEB${index}_URL
		RESOURCE_NAME=WEB${index}_RESOURCE_NAME

		if [[ ${!URL,,} == http://* ]]; then
			TARGET_BLACKBOX_HTTP_PROBE=$(__target_template ${!URL,,} ${!RESOURCE_NAME,,})
			TARGET_BLACKBOX_HTTP_PROBE_LIST+="${TARGET_BLACKBOX_HTTP_PROBE}${NEWLINE}"
		else
			TARGET_BLACKBOX_HTTPS_PROBE=$(__target_template ${!URL,,} ${!RESOURCE_NAME,,})
			TARGET_BLACKBOX_HTTPS_PROBE_LIST+="${TARGET_BLACKBOX_HTTPS_PROBE}${NEWLINE}"
		fi
		((index++))
	done

	PROJECT_NAME=${PROJECT_NAME,,} ENV=${ENV,,} MONITORING_RESOURCE_NAME=${MONITORING_RESOURCE_NAME,,} TARGET_NODE_EXPORTER_LIST=$TARGET_NODE_EXPORTER_LIST TARGET_CADVISOR_LIST=$TARGET_CADVISOR_LIST TARGET_PROMTAIL_LIST=$TARGET_PROMTAIL_LIST TARGET_BLACKBOX_HTTPS_PROBE_LIST=$TARGET_BLACKBOX_HTTPS_PROBE_LIST TARGET_BLACKBOX_HTTP_PROBE_LIST=$TARGET_BLACKBOX_HTTP_PROBE_LIST BLACKBOX_PROBE_INTERVAL=$BLACKBOX_PROBE_INTERVAL envsubst <$PARENT_DIR/templates/prometheus/prometheus.yml >$PACKAGE_MONITORING_DIR/prometheus/prometheus.yml

	sed -i 's/ *$// ; N;/^\n$/D;P;D;' $PACKAGE_MONITORING_DIR/prometheus/prometheus.yml
}

# for a given host param, check if it has valid ip address.
__validate_if_host_ip_address_has_correct_format() {
	local param=$1
	local target_param=$2
	target_value=${!target_param}

	if [[ $param == "IP_ADDRESS" && ! $target_value =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "For parameter '${target_param}', the ip address is not in correct format."
		HAS_ERROR=true
	fi
}
