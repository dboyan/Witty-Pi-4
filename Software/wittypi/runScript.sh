#!/bin/bash
# file: runScript.sh
#
# This script will run automatically after startup, and make next schedule
# according to the "schedule.wpi" script file
#

# delay if first argument exists
if [ ! -z "$1" ]; then
  sleep $1
fi

# get current directory and schedule file path
cur_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
schedule_file="$cur_dir/schedule.wpi"

# utilities
. "$cur_dir/utilities.sh"

# pending until system time gets initialized
while [[ "$(date +%Y)" == *"1969"* ]] || [[ "$(date +%Y)" == *"1970"* ]]; do
  sleep 1
done

# get current timestamp
cur_time=$(current_timestamp)
sleep 0.5
cur_time=$(current_timestamp)

startup_backup_file="$cur_dir/startup_backup.txt"
shutdown_backup_file="$cur_dir/shutdown_backup.txt"

# Function to update current timestamp with the one from startup_backup_file
update_current_timestamp() {
    cur_time=$(cat "$startup_backup_file")
    log "Updated current timestamp with startup backup: $cur_time"
}

if [ -f "$shutdown_backup_file" ] && [ -f "$startup_backup_file" ] && [ -f $schedule_file ]; then
    # File exists, compare timestamps
    shutdown_backup_time=$(cat "$shutdown_backup_file")
    retries=0
    while (( cur_time < shutdown_backup_time )) && [ $retries -lt 10 ]; do
        sleep 0.5
        cur_time=$(current_timestamp)
        ((retries++))
    done
    if (( cur_time < shutdown_backup_time )); then
        # Current timestamp is not in the future, update current timestamp
        update_current_timestamp
    fi
fi

log "Curtime is:  $(date -d @$cur_time +'%Y-%m-%d %H:%M:%S')"

echo "--------------- $(date -d @$cur_time +'%Y-%m-%d %H:%M:%S') ---------------"

extract_timestamp()
{
  IFS=' ' read -r point date timestr <<< $1
  local date_reg='(20[1-9][0-9])-([0-9][0-9])-([0-3][0-9])'
  local time_reg='([0-2][0-9]):([0-5][0-9]):([0-5][0-9])'
  if [[ $date =~ $date_reg ]] && [[ $timestr =~ $time_reg ]] ; then
    echo $(date -d "$date $timestr" +%s)
  else
    echo 0
  fi
}

extract_duration()
{
  local duration=0
  local day_reg='D([0-9]+)'
  local hour_reg='H([0-9]+)'
  local min_reg='M([0-9]+)'
  local sec_reg='S([0-9]+)'
  IFS=' ' read -a parts <<< $*
  for part in "${parts[@]}"
  do
    if [[ $part =~ $day_reg ]] ; then
      duration=$((duration+${BASH_REMATCH[1]}*86400))
    elif [[ $part =~ $hour_reg ]] ; then
      duration=$((duration+${BASH_REMATCH[1]}*3600))
    elif [[ $part =~ $min_reg ]] ; then
      duration=$((duration+${BASH_REMATCH[1]}*60))
    elif [[ $part =~ $sec_reg ]] ; then
      duration=$((duration+${BASH_REMATCH[1]}))
    fi
  done
  echo $duration
}

setup_off_state()
{
  local res=$(check_sys_and_rtc_time)
  if [ ! -z "$res" ]; then
    log "$res"
  fi 
  log "Schedule next startup at:  $(date -d @$1 +'%Y-%m-%d %H:%M:%S')"
  local date=$(date -d "@$1" +"%d")
  local hour=$(date -d "@$1" +"%H")
  local minute=$(date -d "@$1" +"%M")
  local second=$(date -d "@$1" +"%S")
  set_startup_time $date $hour $minute $second
}

setup_on_state()
{
  local res=$(check_sys_and_rtc_time)
  if [ ! -z "$res" ]; then
    log "$res"
  fi 
  log "Schedule next shutdown at: $(date -d @$1 +'%Y-%m-%d %H:%M:%S')"
  local date=$(date -d "@$1" +"%d")
  local hour=$(date -d "@$1" +"%H")
  local minute=$(date -d "@$1" +"%M")
  local second=$(date -d "@$1" +"%S")
  set_shutdown_time $date $hour $minute $second
}

if [ -f $schedule_file ]; then
  begin=0
  end=0
  count=0
  while IFS='' read -r line || [[ -n "$line" ]]; do
    cpos=`expr index "$line" \#`
    if [ $cpos != 0 ]; then
      line=${line:0:$cpos-1}
    fi
    line=$(trim "$line")
    if [[ $line == BEGIN* ]]; then
      begin=$(extract_timestamp "$line")
    elif [[ $line == END* ]]; then
      end=$(extract_timestamp "$line")
    elif [ "$line" != "" ]; then
      states[$count]=$(echo $line)
      count=$((count+1))
    fi
  done < $schedule_file

  if [ $begin == 0 ] ; then
    log 'I can not find the begin time in the script...'
  elif [ $end == 0 ] ; then
    log 'I can not find the end time in the script...'
  elif [ $count == 0 ] ; then
    log 'I can not find any state defined in the script.'
  else
    if [ $((cur_time < begin)) == '1' ] ; then
      cur_time=$begin
    fi
    if [ $((cur_time >= end)) == '1' ] ; then
      log 'The schedule script has ended already.'
    else
      schedule_script_interrupted
      interrupted=$?	# should be 0 if scheduled startup is in the future and shutdown is in the pass
      if [ ! -z "$2" ] && [ $interrupted == 0 ] ; then
        log 'Schedule script is interrupted, revising the schedule...'
      fi
      index=0
      found_states=0
      check_time=$begin
      script_duration=0
      found_off=0
      found_on=0
      while [ $found_states != 2 ] && [ $((check_time < end)) == '1' ] ;
      do
        duration=$(extract_duration ${states[$index]})
        check_time=$((check_time+duration))
        if [ $found_off == 0 ] && [[ ${states[$index]} == OFF* ]] ; then
          found_off=1
        fi
        if [ $found_on == 0 ] && [[ ${states[$index]} == ON* ]] ; then
          found_on=1
        fi
        # find the current ON state and incoming OFF state
        if [ $((check_time >= cur_time)) == '1' ] && ([ $found_states == 1 ] || [[ ${states[$index]} == ON* ]]) ; then
          found_states=$((found_states+1))
          if [[ ${states[$index]} == ON* ]]; then
            if [[ ${states[$index]} == *WAIT ]]; then
              log 'Skip scheduling next shutdown, which should be done externally.'
            else
              if [ ! -z "$2" ] && [ $interrupted == 0 ] ; then
                # schedule a shutdown 1 minute before next startup
                setup_on_state $check_time
                echo "$check_time" > "$shutdown_backup_file"
                log "Updated shutdown backup file with: $check_time"
              else
                setup_on_state $check_time
                echo "$check_time" > "$shutdown_backup_file"
                log "Updated shutdown backup file with: $check_time"
              fi
            fi
          elif [[ ${states[$index]} == OFF* ]] ; then
            if [[ ${states[$index]} == *WAIT ]]; then
              log 'Skip scheduling next startup, which should be done externally.'
            else
              if [ ! -z "$2" ] && [ $interrupted == 0 ] && [ $index != 0 ] ; then
                # jump back to previous OFF state 
                prev_state=${states[$((index-1))]}
                prev_duration=$(extract_duration $prev_state)
                setup_off_state $check_time
                echo "$check_time" > "$startup_backup_file"
                log "Updated startup backup file with: $check_time"
              else
                setup_off_state $check_time
                echo "$check_time" > "$startup_backup_file"
                log "Updated startup backup file with: $check_time"
              fi
            fi
          else
            log "I can not recognize this state: ${states[$index]}"
          fi
        fi
        index=$((index+1))
        if [ $index == $count ] ; then
          index=0
          if [ $script_duration == 0 ] ; then
            if [ $found_off == 0 ] ; then
              log 'I need at least one OFF state in the script.'
              check_time=$end     # skip all remaining cycles
            elif [ $found_on == 0 ] ; then
              log 'I need at least one ON state in the script.'
              check_time=$end     # skip all remaining cycles
            else
              script_duration=$((check_time-begin))
              skip=$((cur_time-check_time))
              skip=$((skip-skip%script_duration))
              check_time=$((check_time+skip))  # skip some useless cycles
            fi
          fi
        fi
      done
    fi
  fi
else
  log "File \"schedule.wpi\" not found, skip running schedule script."
fi

echo '---------------------------------------------------'
