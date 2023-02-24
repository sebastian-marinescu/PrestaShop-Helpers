#!/bin/bash


# Declare variables

DATE=`date "+%Y%m%d"`
PS_CONFIG_FILE=../app/config/parameters.php



# Connect to database and execute relevant scripts

echo
echo "--- Backuping Database ---"
echo

dbHost=$(awk -F"'" '/\database_host/{print $4}' ${PS_CONFIG_FILE})
dbName=$(awk -F"'" '/\database_name/{print $4}' ${PS_CONFIG_FILE})
dbUser=$(awk -F"'" '/\database_user/{print $4}' ${PS_CONFIG_FILE})
dbPass=$(awk -F"'" '/\database_password/{print $4}' ${PS_CONFIG_FILE})

echo "[info]" 
echo "host=\"${dbHost}\""
echo "user=\"${dbUser}\""
echo "database=\"${dbName}\""
echo

mysqldump -h${dbHost} -u${dbUser} -p{dbPass} ${dbName} > dump-${DATE}-${dbName}.sql

echo
