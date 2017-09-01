#!/bin/bash

# Date updated: 2017.09.01

#############
# Goal: Jenkins runs this script on the web server to deploy HTML website.


#############
# How to execute: This script can be executed via Jenkins or in bash locally on the server as root. It is generally kept in /home/jenkins/bin/htmldj.sh. This is because Jenkins is expecting this file in the folder.


#############
# My code is kept in Git repo. When the code is to be deployed, I tag it using following naming convention:
# [d,q,p].yyyymmdd-h24
# d - development environment.  q - qa environment.  p - production
# ex: p.20160927-18
#
# If I needed to deploy twice or more within the same hour, I'd tag the code as p.20160927-18fix01


#############
# How to use this script in bash
# I use the same script to test code under active development.
# I rsync up files and run the script with just 1 option as shown below.
# ./htmldj.sh paulcodr.co        # >> deploys files rsynced upto the server
# This allow me a very rapid code/deploy/test loop.


##############
# How to use this script with Jenkins.
# Note that all following 4 commands are to be executed on the local Mac computer.
# The script needs 1 or 2 options specified which are URL (first, required) and Git-tag-name (second, optional).
# This script is usually executed by Jenkins using Parameter Build. But the script can be executed locally on the server.

# 1. Get UDT time by running following script on my Mac. That script puts date-time stamps (yyyymmdd-h24) in UDT into the clipboard.
# bin/udtdate.sh
#
#
# 2. Assign date-time stamp in UDT to variable "_tagname" by pasting the value stored in clipboard.
# _tagname="p.20170519-19"
#
# If I were deploying again within the same hour, I'd use following value.
# _tagname="p.20170519-19fix01"
#
#
# 3. Run following command. This step is needed because Jenkins is running behind nginx. The value of _CRUMB will be used with curl command in the next step.
# _CRUMB=$(curl -s 'https://pchu:591951234567890bcd60@jen.myserver.com/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,":",//crumb)')
#
#
# 4. Following curl command triggers a build job on the Jenkins server. Note the value for "tagused" needs to be updated for each build job. Since I'm using variable $_tagname, the curl command will pass correct parameters to the Jenkins build job.
#
# curl -X POST -H "$_CRUMB" "https://pchu:591951234567890bcd60@jen.myserver.com/job/paulcodr.co-container/job/paulcodr.co/buildWithParameters?token=deployprod&tagused=$_tagname"
# ```
#
# Once the build job is triggered, Jenkins server pulls the code from the Git repo, scps the files over to the web server, and remotely executes  htmldj.sh  on the web server. In my setup, the htmldj.sh is saved in /home/jenkins/bin/htmldj.sh.
#
# Finally htmldj.sh on the web server then tars up the data folder as a backup, copies in files, and sets permissions.


##############
# Doc Roots and URLs
# /data/www/public_html/paulcodr.co/paulcodr.co  >> https://paulcodr.co production environment
# /data/www/public_html/paulcodr.co/devenv.paulcodr.co  >> https://devenv.paulcodr.co  dev environment
# /data/www/public_html/paulcodr.co/qaenv.paulcodr.co  >> https://qaenv.paulcodr.co   qa environment


#####################
# Global variables declaration
#####################
# Array to hold list of folders containing old code
declare _old_folder
declare _old_folder_array

# Variables holding source/dest/rsynced-up-folder.
declare _source_folder
declare _dest_folder
declare _rsyncFiles

declare _websiteGlobal
declare _gitTagGlobal

_data=data   # _data and _web combine to show /data/www/ is html files are served from by Apache
_web=www




############
# Variables you MUST check/update.
############

_website=${1}   # example.com    website folder of project

function func_website_check(){

	case $_website in
	    *.com|*.co|*.org|*.vag) echo "Verified valid URL was given in the 1st argument of the script.." ;;
	    *)               echo -e "Script is exiting without making any changes because no valid URL was given in the 1st argument of the script.\nThis script accepts URLs ending with following\n.com\n.org\n.co\n.vag" && exit 1 ;;
	esac


	if [[ -z $_website ]]; then
	  echo -e "Script is exiting without making any changes because of following:\n\nNo valid argument needed to determine website URL was given for the script. \nFirst argument (required) should be a URL like example.com or example.com. Second argument (optional) should be Git tag (ex: q.20170605)"
		exit 1
	elif [[ $_website != *.* ]]; then
	  echo -e "Exiting because no valid URL was given in an argument for the script. \nFirst argument (required) should be URL like example.com or example.com. \nSecond argument (optional) should be a Git tag (ex: q.20170605)"
		exit 1
	elif [[ $_website == */* ]] && [[ $_website == *.* ]]; then
		_website=`basename ${_website}`
	fi


	if [[ $_website != *.* ]]; then
	  echo "Final check of website '$_website' shows it does not include a dot, so script is exiting without making any changes." # ex: a.b/a.com/new was given as 1st argument
		exit 1
	fi

	_websiteGlobal=$_website
}


_gitTag=${2}   # ex: q.20170603-18 or p.20170607-19 or d.20170603-20fix or blank
function func_git_tag_check(){
if [[ -z $_gitTag ]]; then
  #echo "Deploying to Dev environment as no 2nd argument given. "
	_gitTag=d
	_useRsync=y   # Runs func_rsync_file_check to see if files were rsynced up.
elif [[ $_gitTag == d.* ]]; then
	_gitTag=${_gitTag:0:1}
	#echo "Deploying to dev environment."

elif [[ $_gitTag == q.* ]]; then
	_gitTag=${_gitTag:0:1}
	#echo "Deploying to QA environment."

elif [[ $_gitTag == p.* ]]; then
	_gitTag=${_gitTag:0:1}
	#echo "Deploying to Production environment."

else
	echo -e "Script is exiting without making any changes because no valid Git tag was provided in the 2nd argument. 2nd argument must be either blank, or start with p.123, d.2017, or q.xxx\nValid example of Git tag used: q.20160924-01"
	exit 1
fi

	_gitTagGlobal=${_gitTag}

	echo $_gitTagGlobal
}



_home_folder="home/jenkins"   # home dir of jenkins user used by Jenkins.

_homeRsyncedFiles="${_home_folder}/devsite/${_websiteGlobal}"   # where I rsync up files under active development
_filesFromGit="${_home_folder}/build/"   # folder where Jenkins pushes website files to

# Specify the number of backup copies you want to keep. Mainly used to keep down folder size.
_folders_to_keep=5


############
# Variables you do not need to update.
############
# This is necessary because of the way 'tail -n +6' works. Nothing to change here.
_folders_value=$(($_folders_to_keep + 1))
_log_dir=home/jenkins/logs
_log=$_log_dir/deploy-$(TZ=":UTC" date +"%Y-%m-%d").log   # /home/jenkins/logs/deploy-...

# Date/time stamp
_nowMin=$(TZ=":UTC" date +"%Y-%m-%d_%H-%M-%Z")
_nowMin=${_nowMin}     # timestamp for naming backup files

_nowDay=$(TZ=":UTC" date +"%Y-%m-%d")
_nowDay=${_nowDay}     # timestamp for naming backup files



############
# Script
############
function func_start_log(){
mkdir /$_log_dir 2> /dev/null
chmod -R 775 /$_filesFromGit

chown -R jenkins:jenkins /$_filesFromGit
echo "====================" >> /$_log
}


function func_rsync_file_check(){
	if [[ $_useRsync == "y" ]] ; then
		_rsyncFiles=`find /$_homeRsyncedFiles -type f | wc -l`
	fi

	if [[ $_rsyncFiles == 0 ]] ; then
	echo -e "Script will exit without making any changes:\n\n1. You specified only 1 script argument, meaning you specified no Git tag to deploy.\n2. This would mean copying rsynced up files to destination folder: coping from /$_homeRsyncedFiles/  -->  $_dest_folder/.\n3. HOWEVER, there are no files in /$_homeRsyncedFiles/. Hence the script exited without manking any changes."  >> /$_log
	exit 1
	fi
}



# Determine source and destination folders.
function func_get_source_dest(){

  # following is defined here because of ${_websiteGlobal}
  _homeRsyncedFiles="${_home_folder}/devsite/${_websiteGlobal}"   # where I rsync up files under development
  _filesFromGit="${_home_folder}/build/"   # folder where Jenkins pushes website files to

	if [[ ${_gitTagGlobal} == "d" ]] && [[ $_useRsync == "y" ]]; then
		_source_folder=${_homeRsyncedFiles} # ex: /home/jenkins/devsite/${_websiteGlobal}
		_dest_folder="$_data/$_web/${_websiteGlobal}/devenv.${_websiteGlobal}"
		echo -e "Script will attempt deploying to Dev environment\nCopying files from /$_source_folder --> /$_dest_folder." >> /$_log
	elif [ ${_gitTagGlobal} == "d" ]; then
		_source_folder=${_filesFromGit} # ex: /home/jenkins/build/${_websiteGlobal}
		_dest_folder="$_data/$_web/${_websiteGlobal}/devenv.${_websiteGlobal}"
		echo -e "Script will attempt deploying to Dev environment\nCopying files from /$_source_folder --> /$_dest_folder." >> /$_log
	elif [ ${_gitTagGlobal} == "q" ]; then
		_source_folder=${_filesFromGit} # ex: /home/jenkins/build/${_websiteGlobal}
		_dest_folder="$_data/$_web/${_websiteGlobal}/qaenv.${_websiteGlobal}"
		echo -e "Script will attempt deploying to QA environment\nCopying files from /$_source_folder --> /$_dest_folder." >> /$_log
	elif [ ${_gitTagGlobal} == "p" ]; then
		_source_folder=${_filesFromGit} # ex: ex: /home/jenkins/build/${_websiteGlobal}
		_dest_folder="$_data/$_web/${_websiteGlobal}/${_websiteGlobal}"  #ex:
		echo -e "Script will attempt deploying to Production environment\nCopying files from /$_source_folder --> /$_dest_folder." >> /$_log
	fi

	echo "func_get_source_dest $_source_folder"
	echo "func_get_source_dest $_dest_folder"
}


# Determine folder to backup files
function func_get_old(){
	_old_folder="$_data/$_web/${_websiteGlobal}/${_gitTagGlobal:0:1}.${_websiteGlobal}_old"  # ex: data/www/destwebsite.cmm/d.destwebsite.com_old
	_old_folder_array="(/$_old_folder/*)"

	echo "Backup folder of old filese is $_nowMin /$_old_folder"  >> /$_log
}


# If deploying to non-production, remove Google Analytics JS lines
function func_for_nonproduction(){
	if [[ ${_gitTagGlobal:0:1} == "d" ]]; then
		find /${_source_folder} -type f -exec sed -i '/analytics/d' {} \; && echo -e "$_nowMin Deploying dev version. Removed Google Analytics JS from /${_source_folder}"  >> /$_log
	elif [[ ${_gitTagGlobal:0:1} == "q" ]]; then
		find /${_source_folder} -type f -exec sed -i '/analytics/d' {} \; && echo -e "$_nowMin Deploying QA version. Removed Google Analytics JS from /${_source_folder}"  >> /$_log
	fi
}


# MOVE older website files to backup folder.
function func_remove_old(){
	mkdir -p /$_old_folder/$_nowMin/ > /dev/null 2>&1
	mv /$_dest_folder/{*,.[^.]*} /$_old_folder/$_nowMin/ > /dev/null 2>&1 && echo "$_nowMin Moved content of /$_dest_folder/ to /$_old_folder/$_nowMin/" >> /$_log

	for i in ${_old_folder_array[@]}
	do
		/bin/ls -dt /$_old_folder/* | /usr/bin/tail -n +$_folders_value | /usr/bin/xargs /bin/rm -rf  #keep only latest $_folders_value sets and delete older ones
	done
	echo -e "\n$_nowMin Only  $_folders_to_keep  newer subfolders are now in /$_old_folder/. \n" >> /$_log
}


# Copy new files to destination folder and set permissions.
function func_copy_in_files(){
	mkdir /$_dest_folder/ > /dev/null 2>&1
	echo "Created /$_dest_folder/" >> /$_log

  echo "func_copy_in_files  /${_source_folder} "
	rsync -a --exclude=.DS_Store --exclude=.git --exclude=.gitignore --exclude=.idea --exclude=.name --exclude=/${_source_folder}/1-* --exclude=/${_source_folder}/1-* /${_source_folder}/{*,.[^.]*} /$_dest_folder/ > /dev/null 2>&1    # exclude=/1-* excluces only 1-* directories on the top level of the source dir.
	chmod 775 /${_data}/${_web}
	chown apache:apache /${_data}/${_web}
	chown -R apache:apache /$_dest_folder
	chmod 775 -R /$_dest_folder
	find /$_dest_folder -type d -exec chmod 755 {} \; && find /$_dest_folder -type f -exec chmod 644 {} \; && echo "$_noGwMin Copied files to destination folder and set permission" >> /$_log

	chown jenkins:jenkins /$_log
}


func_start_log
func_website_check
func_git_tag_check
func_rsync_file_check
func_get_source_dest
func_get_old
func_for_nonproduction
func_remove_old
func_copy_in_files
