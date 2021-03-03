#!/bin/bash

# Declare variables

LOCAL_DIRECTORY=$(pwd)/sql_upgrades

OLD_PS_VERSION=1.7.2.4
NEW_PS_VERSION=1.7.7.2

PS_CONFIG_FILE=../app/config/parameters.php

oldSemver=( ${OLD_PS_VERSION//./ } )
oldMajor=${oldSemver[0]}
oldMinor=${oldSemver[1]}
oldPatch=${oldSemver[2]}
oldLabel=${oldSemver[3]}

newSemver=( ${NEW_PS_VERSION//./ } )
newMajor=${newSemver[0]}
newMinor=${newSemver[1]}
newPatch=${newSemver[2]}
newLabel=${newSemver[3]}

migrationScripts=()

# Loop through sql scripts

for f in ${LOCAL_DIRECTORY}/*.sql; do

    fileName="$(basename ${f} .sql)"

    currentSemver=( ${fileName//./ } )
    currentMajor=${currentSemver[0]}
    currentMinor=${currentSemver[1]}
    currentPatch=${currentSemver[2]}
    currentLabel=${currentSemver[3]}

    if [[ ${currentMajor} -ge ${oldMajor} && ${currentMajor} -le ${newMajor} ]];then
        if [[ ${currentMinor} -ge ${oldMinor} && ${currentMinor} -le ${newMinor} ]];then
            if [[ ${currentPatch} -ge ${oldPatch} && ${currentPatch} -le ${newPatch} ]];then

                if [[ ${currentPatch} -eq ${newPatch} && ${currentLabel} -gt ${newLabel} ]];then
                    continue
                fi

                if [[ ${currentPatch} -eq ${oldPatch} && ${currentLabel} -lt ${oldLabel} ]];then
                    continue
                fi

                echo "${fileName} -- is in patch range"
                migrationScripts+=( ${f} )

            fi
        fi
    fi
done

# Connect to database and execute relevant scripts

echo
echo "--- Connecting to Database and starting ${#migrationScripts[@]} migration scripts ---"
echo

dbHost=$(awk -F"'" '/\database_host/{print $4}' ${PS_CONFIG_FILE})
dbName=$(awk -F"'" '/\database_name/{print $4}' ${PS_CONFIG_FILE})
dbUser=$(awk -F"'" '/\database_user/{print $4}' ${PS_CONFIG_FILE})
dbPass=$(awk -F"'" '/\database_password/{print $4}' ${PS_CONFIG_FILE})

touch .dbconf
echo "[client]" >> .dbconf
echo "host=\"${dbHost}\"" >> .dbconf
echo "user=\"${dbUser}\"" >> .dbconf
echo "password=\"${dbPass}\"" >> .dbconf

for script in ${migrationScripts[@]}; do
    echo "Executing ${script}"
    mysql --defaults-extra-file=.dbconf --force ${dbName} <  ${script} || true
done

rm .dbconf
