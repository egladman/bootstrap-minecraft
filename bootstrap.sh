#!/bin/bash

################################################################################
#                                                                              #
#                                  minutemen                                   #
#                           Written By: Eli Gladman                            #
#                                                                              #
#                                                                              #
#                                   EXAMPLE                                    #
#                               ./bootstrap.sh                                 #
#                                                                              #
#                https://github.com/egladman/bootstrap-minecraft               #
#                                                                              #
################################################################################

# MC_* denotes Minecraft or Master Chief 
MC_SERVER_UUID="$(uuidgen)" # Each server instance has its own value
MC_PARENT_DIR="/opt/minecraft"
MC_SERVER_INSTANCES_DIR="${MC_PARENT_DIR}/instances"
MC_BIN_DIR="${MC_PARENT_DIR}/bin"
MC_CACHE_DIR="${MC_PARENT_DIR}/.downloads"
MC_INSTALL_DIR="${MC_SERVER_INSTANCES_DIR}/${MC_SERVER_UUID}"
MC_MAX_HEAP_SIZE="896M" # This vargets redefined later on. Not some random number i pulled out of a hat: 1024-128=896
MC_USER="minecraft" # For the love of god don't be an asshat and change to "root"
MC_EXECUTABLE_START="start"
MC_EXECUTABLE_START_PATH="${MC_PARENT_DIR}/bin/${MC_EXECUTABLE_START}"
MC_SYSTEMD_SERVICE_NAME="minutemen"
MC_SYSTEMD_SERVICE_PATH="/etc/systemd/system/${MC_SYSTEMD_SERVICE_NAME}.service"

# M_* denotes Minecraft Mod
M_FORGE_DOWNLOAD_URL="https://files.minecraftforge.net/maven/net/minecraftforge/forge/1.14.3-27.0.25/forge-1.14.3-27.0.25-installer.jar"
M_FORGE_DOWNLOAD_SHA1SUM="7b96f250e52584086591e14472b96ec2648a1c9c"
M_FORGE_INSTALLER_JAR="$(basename ${M_FORGE_DOWNLOAD_URL})"
M_FORGE_INSTALLER_JAR_PATH="${MC_INSTALL_DIR}/${M_FORGE_INSTALLER_JAR}"

# SYS_* denotes System

# MU_ * denotes Mutex
MU_JAVA_CHECK_PASSED=1
MU_USER_CHECK_PASSED=1
MU_FORGE_DOWNLOAD_CACHED=1

# CLR_* denotes Color
CLR_RED="\033[0;31m"
CLR_GREEN="\033[32m"
CLR_YELLOW="\033[33m"
CLR_CYAN="\033[36m"
CLR_NONE="\033[0m"

# FL_ * denotes Flag
FL_VERBOSE=1

# Variables that are dynamically set later
M_FORGE_DOWNLOAD_ACTUAL_SHA1SUM=""
M_FORGE_UNIVERSAL_JAR_PATH=""
SYS_TOTAL_MEMORY_KB=""
SYS_TOTAL_MEMORY_MB=""

# Helpers
_log() {
    echo -e ${0##*/}: "${@}" 1>&2
}

_debug() {
    if [ "${FL_VERBOSE}" -eq 0 ]; then
        _log "${CLR_CYAN}DEBUG:${CLR_NONE} ${@}"
    fi
}

_warn() {
    _log "${CLR_YELLOW}WARNING:${CLR_NONE} ${@}"
}

_success() {
    _log "${CLR_GREEN}SUCCESS:${CLR_NONE} ${@}"
}

_die() {
    _log "${CLR_RED}FATAL:${CLR_NONE} ${@}"
    exit 1
}

_usage() {
cat << EOF
${0##*/} [-h] [-v] [-c string] [-t string] -- Build/Provision Minecraft Servers with ForgeMods Support
where:
    -h  show this help text
    -v  verbose
EOF
}

while getopts ':h :v' option; do
    case "${option}" in
        h|\?) _usage
           exit 0
           ;;
        v) FL_VERBOSE=0
           ;;
        :) printf "missing argument for -%s\n" "${OPTARG}"
           _usage
           exit 1
           ;;
    esac
done
shift $((OPTIND - 1))

# Where the magic happens
command -v systemctl >/dev/null 2>&1 || _die "systemd not found. No other init systems are currently supported." # Sanity check

if [ -d "${MC_SYSTEMD_SERVICE_PATH}" ]; then
    _debug "Attempting to stop ${MC_SYSTEMD_SERVICE_NAME}.service"
    systemctl daemon-reload || _warn "Failed to run \"systemctl daemon-reload\""
    systemctl stop "${MC_SYSTEMD_SERVICE_NAME}" || _log "${MC_SYSTEMD_SERVICE_NAME}.service not running..."
fi

if [ -f "${MC_CACHE_DIR}/${M_FORGE_INSTALLER_JAR}" ]; then
    _debug "Cached ${M_FORGE_INSTALLER_JAR} found."
    MU_FORGE_DOWNLOAD_CACHED=0
fi

_debug "Checking for user: ${MC_USER}"
id -u "${MC_USER}" >/dev/null 2>&1 && _debug "User: ${MC_USER} found." || {
    _debug "User: ${MC_USER} not found. Creating..."
    # Disabling passwords is traditonally frowned upon, however since the host
    # isn't intended for multi-purpose use we're going to relax...
    command -v apt-get >/dev/null 2>&1 && adduser --disabled-password --gecos "" "${MC_USER}" >/dev/null 2>&1 && {
        MU_USER_CHECK_PASSED=0
    }

    command -v dnf >/dev/null 2>&1 && adduser "${MC_USER}" >/dev/null 2>&1 && {
        MU_USER_CHECK_PASSED=0
    }
    wait # This is going to bite me in the ass one day...

    if [[ $MU_USER_CHECK_PASSED -ne 0 ]]; then
        _die "Failed to run \"adduser ${MC_USER}\". Does the user already exist?"
    fi
}

_debug "Checking for directory: ${MC_INSTALL_DIR}"
if [ ! -d "${MC_INSTALL_DIR}" ]; then
    _debug "Creating directory: ${MC_INSTALL_DIR}"
    mkdir -p -m 700 "${MC_INSTALL_DIR}" "${MC_BIN_DIR}" "${MC_CACHE_DIR}" || {
        _die "Failed to create ${MC_INSTALL_DIR} and set permissions"
    }
    chown -R "${MC_USER}":"${MC_USER}" "${MC_INSTALL_DIR}"
else
    _log "Directory: ${MC_INSTALL_DIR} already exists. Proceeding with install."
fi

if [[ ${MU_FORGE_DOWNLOAD_CACHED} -eq 0 ]]; then
    _debug "Copying ${MC_CACHE_DIR}/${M_FORGE_INSTALLER_JAR} to ${MC_INSTALL_DIR}/"
    cp "${MC_CACHE_DIR}/${M_FORGE_INSTALLER_JAR}" "${MC_INSTALL_DIR}/" || {
        _die "Failed to copy ${MC_CACHE_DIR}/${M_FORGE_INSTALLER_JAR} to ${MC_INSTALL_DIR}/"
    }
else
    _debug "Downloading ${M_FORGE_INSTALLER_JAR}"
    wget "${M_FORGE_DOWNLOAD_URL}" -P "${MC_INSTALL_DIR}" || _die "Failed to fetch ${M_FORGE_DOWNLOAD_URL}"
fi

# Validate file download integrity
M_FORGE_DOWNLOAD_ACTUAL_SHA1SUM="$(sha1sum ${M_FORGE_INSTALLER_JAR_PATH} | cut -d' ' -f1)"
if [ "${M_FORGE_DOWNLOAD_ACTUAL_SHA1SUM}" != "${M_FORGE_DOWNLOAD_SHA1SUM}" ]; then
    _debug "M_FORGE_DOWNLOAD_ACTUAL_SHA1SUM: ${M_FORGE_DOWNLOAD_ACTUAL_SHA1SUM}"
    _debug "M_FORGE_DOWNLOAD_SHA1SUM: ${M_FORGE_DOWNLOAD_SHA1SUM}"
    _die "sha1sum doesn't match for ${M_FORGE_INSTALLER_JAR_PATH}"
fi

# Install Ubuntu dependencies
apt_dependencies=(
    "openjdk-8-jdk" # Must be the first index!! openjdk-11-jdk works fine with vanilla Minecraft, but not with Forge
)
command -v apt-get >/dev/null 2>&1 && sudo apt-get update -y && sudo apt-get install -y "${apt_dependencies[@]}"

# Install Fedora dependencies
dnf_dependencies=(
    "java-1.8.0-openjdk" # Must be the first index!!
)
command -v dnf >/dev/null 2>&1 && sudo dnf update -y && sudo dnf install -y "${dnf_dependencies[@]}"

# Rebinding /usr/bin/java could negatively impact other aspects of the os stack i'm NOT going to automate it.
command -v dnf >/dev/null 2>&1 && update-alternatives --list | grep "^java.*${dnf_dependencies[0]}" && {
    MU_JAVA_CHECK_PASSED=0
    _debug "${dnf_dependencies[0]} is the default. Proceeding..."
}

command -v apt-get >/dev/null 2>&1 && update-alternatives --list | grep "^java.*${apt_dependencies[0]}" && {
    MU_JAVA_CHECK_PASSED=0
    _debug "${apt_dependencies[0]} is the default. Proceeding..."
}
wait # Just incase the update-alternatives commands don't return fast enough...

if [[ $MU_JAVA_CHECK_PASSED -ne 0 ]]; then
    _die "openjdk 8 is NOT the default java. Run \"update-alternatives -show java\" for more info."
fi

SYS_TOTAL_MEMORY_KB="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
SYS_TOTAL_MEMORY_MB="$(( $SYS_TOTAL_MEMORY_KB / 1024 ))"
MC_MAX_HEAP_SIZE="$(( $SYS_TOTAL_MEMORY_MB - 128 ))M" # Leave 128MB memory for the system to run properly

chown -R "${MC_USER}":"${MC_USER}" "${MC_INSTALL_DIR}"

su - "${MC_USER}" -c "cd ${MC_INSTALL_DIR}; java -jar ${M_FORGE_INSTALLER_JAR_PATH} --installServer" && {
    _debug "Deleting ${M_FORGE_INSTALLER_JAR_PATH}"
    rm "${M_FORGE_INSTALLER_JAR_PATH}" || _warn "Failed to delete ${M_FORGE_INSTALLER_JAR_PATH}"
} || {
    _die "Failed to execute ${M_FORGE_INSTALLER_JAR_PATH}"
}
_success "${M_FORGE_INSTALLER_JAR} completed!"

# the "cd" ensures we get just the basename 
M_FORGE_UNIVERSAL_JAR_PATH="$(cd ${MC_INSTALL_DIR}; ls ${MC_INSTALL_DIR}/forge-*.jar | grep -v ${M_FORGE_INSTALLER_JAR})"
M_FORGE_UNIVERSAL_JAR="$(basename ${M_FORGE_UNIVERSAL_JAR_PATH})"

read -r -d '' MC_EXECUTABLE_START_CONTENTS <<'EOF'
#!/bin/bash
# ${MC_EXECUTABLE_START_PATH} Generated by ${MC_SYSTEMD_SERVICE_NAME}

java -Xmx${MC_MAX_HEAP_SIZE} -jar ${MC_SERVER_INSTANCES_DIR}/\$1/${M_FORGE_UNIVERSAL_JAR}
EOF

_debug "Checking for ${MC_EXECUTABLE_START_PATH}"
if [ ! -f "${MC_EXECUTABLE_START_PATH}" ]; then
    # Create the wrapper script that systemd invokes
    _debug "Creating ${MC_EXECUTABLE_START_PATH}"
    echo "${MC_EXECUTABLE_START_CONTENTS}" > "${MC_EXECUTABLE_START_PATH}" || _die "Failed to create ${MC_EXECUTABLE_START_PATH}"
    chmod +x "${MC_EXECUTABLE_START_PATH}" || _die "Failed to perform chmod on ${MC_EXECUTABLE_PATH}"
fi

su - "${MC_USER}" -c "cd ${MC_INSTALL_DIR}; /bin/bash ${MC_EXECUTABLE_PATH}" && {
    # When executed for the first time, the process will exit. We need to accept the EULA
    _debug "Accepting end user license agreement"
    sed -i -e 's/false/true/' "${MC_INSTALL_DIR}/eula.txt" || _die "Failed to modify \"${MC_INSTALL_DIR}/eula.txt\". Did ${M_FORGE_UNIVERSAL_JAR} return exit code 0?"
} || _die "Failed to execute ${MC_EXECUTABLE_PATH} for the first time."

_debug "Creating ${MC_SYSTEMD_SERVICE_PATH}"
cat << EOF > "${MC_SYSTEMD_SERVICE_PATH}" || _die "Failed to create systemd service"
[Unit]
Description=minecraft server: %i
After=network.target

[Service]
Type=simple
User=${MC_USER}
Group=${MC_USER}
WorkingDirectory=${MC_SERVER_INSTANCES_DIR}/%i
ExecStart=/bin/bash ${MC_SERVER_INSTANCES_DIR}/%i/${MC_EXECUTABLE_START}
Restart=on-failure
RestartSec=60s

[Install]
WantedBy=multi-user.target

EOF

_log "Configuring systemd to automatically start ${MC_SYSTEMD_SERVICE_NAME}.service on boot"
systemctl enable "${MC_SYSTEMD_SERVICE_NAME}" || _die "Failed to permanently enable ${MC_SYSTEMD_SERVICE_NAME} with systemd"

_log "Starting ${MC_SYSTEMD_SERVICE_NAME}.service. This can take awhile... Go grab some popcorn."
systemctl start "${MC_SYSTEMD_SERVICE_NAME}" || _die "Failed to start ${MC_SYSTEMD_SERVICE_NAME} with systemd"

ip_addresses="$(hostname -I)"
_success "Server is now running. Go crazy ${ip_addresses}"
 
