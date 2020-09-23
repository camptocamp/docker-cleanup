#!/bin/bash

checkPatterns() {
    keepit=$3
    if [ -n "$1" ]; then
      for PATTERN in $(echo $1 | tr "," "\n"); do
        if [[ $PATTERN = '.' ]]; then
          if [ $DEBUG ]; then echo "DEBUG: Global Match $PATTERN - keeping"; fi
          keepit=1
        elif [[ "$2" = $PATTERN* ]]; then
          if [ $DEBUG ]; then echo "DEBUG: Matches $PATTERN - keeping"; fi
          keepit=1
        else
          if [ $DEBUG ]; then echo "DEBUG: No match for $PATTERN"; fi
        fi
      done
    fi
    return $keepit
}

# Remove Images. Read the IDs from the file ToBeCleaned
# Uses tags if the image has one or more
removeImages() {
    if [ -s ToBeCleaned ]; then
        echo "Start to clean $(cat ToBeCleaned | wc -l) images"
        for image in $(cat ToBeCleaned)
        do
            tags=$(docker inspect --format='{{range $tag := .RepoTags}}{{$tag}}  {{end}}' $image)
            if [[ -n "$tags" ]]; then
                docker rmi $tags
            else
                docker rmi $image 2>/dev/null
            fi
        done
        (( DIFF_LAYER=${ALL_LAYER_NUM}- $(docker images -aq | wc -l) ))
        (( DIFF_IMG=$(cat ImageIdList | wc -l) - $(docker images -q | wc -l) ))
        if [ ! ${DIFF_LAYER} -gt 0 ]; then
                DIFF_LAYER=0
        fi
        if [ ! ${DIFF_IMG} -gt 0 ]; then
                DIFF_IMG=0
        fi
        echo "Done! ${DIFF_IMG} images and ${DIFF_LAYER} layers have been cleaned."
    else
        echo "No images need to be cleaned"
    fi
}

if [ ! -e "/var/run/docker.sock" ]; then
    echo "=> Cannot find docker socket(/var/run/docker.sock), please check the command!"
    exit 1
fi

if docker version >/dev/null; then
    echo "docker is running properly"
else
    echo "Cannot run docker binary at /usr/bin/docker"
    echo "Please check if the docker binary is mounted correctly"
    exit 1
fi

if [ ! "${CLEAN_PERIOD}" ]; then
    echo "=> CLEAN_PERIOD not defined, use the default value of 1800."
    CLEAN_PERIOD=1800
fi

if [ "${DELAY_TIME}" == "**None**" ]; then
    echo "=> DELAY_TIME not defined, use the default value."
    DELAY_TIME=1800
fi

if [ "${KEEP_IMAGES}" == "**None**" ]; then
    unset KEEP_IMAGES
fi

if [ "${KEEP_CONTAINERS}" == "**None**" ]; then
    unset KEEP_CONTAINERS
fi

if [ "${KEEP_CONTAINERS}" == "**All**" ]; then
    KEEP_CONTAINERS="."
fi

if [ "${KEEP_CONTAINERS_NAMED}" == "**None**" ]; then
    unset KEEP_CONTAINERS_NAMED
fi

if [ "${KEEP_CONTAINERS_NAMED}" == "**All**" ]; then
    KEEP_CONTAINERS_NAMED="."
fi

if [ "${KEEP_VOLUMES_NAMED}" == "**None**" ]; then
    unset KEEP_VOLUMES_NAMED
fi

if [ "${KEEP_VOLUMES_NAMED}" == "**All**" ]; then
    KEEP_VOLUMES_NAMED="."
fi

if [ ! $KEEP_VOLUMES_UNNAMED ]; then
    KEEP_VOLUMES_UNNAMED="true"
fi

if [ ! $VOLUME_INFOS_IMAGE ]; then
    VOLUME_INFOS_IMAGE='camptocamp/volume_info:1.0.0'
fi

if [ ! $DURATION_IMAGE ]; then
    DURATION_IMAGE='camptocamp/duration:1.0.0'
fi

if [ ! $KEEP_VOLUMES_ATIME_SINCE ]; then
    KEEP_VOLUMES_ATIME_SINCE="0"
fi

if [ ! $KEEP_VOLUMES_MTIME_SINCE ]; then
    KEEP_VOLUMES_MTIME_SINCE="0"
fi


if [ "${LOOP}" != "false" ]; then
    LOOP=true
fi

if [ "${DEBUG}" == "0" ]; then
    unset DEBUG
fi

if [ $DEBUG ]; then echo "DEBUG ENABLED"; fi


echo "=> Run the clean script every ${CLEAN_PERIOD} seconds and delay ${DELAY_TIME} seconds to clean."

trap '{ echo "User Interupt."; exit 1; }' SIGINT
trap '{ echo "SIGTERM received, exiting."; exit 0; }' SIGTERM
# TODO: Is this still needed?
IFS='
 '
while [ 1 ]
do
    if [ $DEBUG ]; then echo "DEBUG: Starting loop"; fi

    # Get all image ID for stats reporting in removeImages().
    # Stats can be affected by outside operations
    ALL_LAYER_NUM=$(docker images -aq | wc -l)
    docker images -q --no-trunc | sort -o ImageIdList


    echo "=> Removing exited/dead containers"
    EXITED_CONTAINERS_IDS="`docker ps -a -q -f status=exited -f status=dead | xargs echo`"
    for CONTAINER_ID in $EXITED_CONTAINERS_IDS; do
      CONTAINER_IMAGE=$(docker inspect --format='{{(index .Config.Image)}}' $CONTAINER_ID)
      CONTAINER_NAME=$(docker inspect --format='{{(index .Name)}}' $CONTAINER_ID | sed 's/^\///')
      # TODO: Add label collection
      if [ $DEBUG ]; then echo "DEBUG: Check container image $CONTAINER_IMAGE named $CONTAINER_NAME"; fi
      keepit=0
      checkPatterns "${KEEP_CONTAINERS}" "${CONTAINER_IMAGE}" $keepit
      keepit=$?
      checkPatterns "${KEEP_CONTAINERS_NAMED}" "${CONTAINER_NAME}" $keepit
      keepit=$?
      # TODO: Add label check.  Look at jq vs sed
      if [[ $keepit -eq 0 ]]; then
        echo "Removing stopped container $CONTAINER_ID"
        # No -v for safety in case of shared volumes.  Remove unused volumes at the end.
        docker rm $CONTAINER_ID
      fi
    done
    unset CONTAINER_ID


    echo "=> Looking for unstarted created containers"
    # Get all containers in "created" state
    rm -f CreatedContainerIdList
    docker ps -a -q -f status=created | sort > CreatedContainerIdList

    if [[ $(cat CreatedContainerIdList | wc -l) -eq 1 ]]; then
      # Wait before cleaning containers and images
      echo "=> Waiting ${DELAY_TIME} seconds before cleaning"
      sleep ${DELAY_TIME} & wait

      echo "=> Removing unstarted created containers"
      # Remove created containers that haven't managed to start within the DELAY_TIME interval
      rm -f CreatedContainerToClean
      comm -12 CreatedContainerIdList <(docker ps -a -q -f status=created | sort) > CreatedContainerToClean
      if [ -s CreatedContainerToClean ]; then
          echo "=> Start to clean $(cat CreatedContainerToClean | wc -l) created/stuck containers"
          if [ $DEBUG ]; then echo "DEBUG: Removing unstarted containers"; fi
          # No -v for safety in case of shared volumes.  Remove unused volumes at the end.
          docker rm $(cat CreatedContainerToClean)
      fi
    else
      if [ $DEBUG ]; then echo "DEBUG: No unstarted created containers found.  Skipping delay time"; fi
    fi


    echo "=> Removing unused images"
    CONTAINER_ID_LIST=$(docker ps -aq --no-trunc)
    # Get Image ID that is used by a containter
    rm -f ContainerImageIdList
    touch ContainerImageIdList
    for CONTAINER_ID in ${CONTAINER_ID_LIST}; do
        echo "$(docker inspect ${CONTAINER_ID} --format='{{.Image}}')" >> ContainerImageIdList
    done
    sort ContainerImageIdList -o ContainerImageIdList

    # Remove the images being used by containers from the delete list
    comm -23 ImageIdList ContainerImageIdList > ToBeCleanedImageIdList

    # Remove those reserved images from the delete list
    if [ -n "${KEEP_IMAGES}" ]; then
      rm -f KeepImageIdList
      touch KeepImageIdList
      # This looks to see if anything matches the pattern
      docker images --no-trunc | (
        while read repo tag image junk; do
          keepit=0
          if [ $DEBUG ]; then echo "DEBUG: Check image $repo:$tag"; fi
          checkPatterns "${KEEP_IMAGES}" "${repo}:${tag}" $keepit
          keepit=$?
          if [[ $keepit -eq 1 ]]; then
            if [ $DEBUG ]; then echo "DEBUG: Marking image $repo:$tag to keep"; fi
            echo $image >> KeepImageIdList
          fi
        done
      )
      # This explicitly looks for the images specified
      arr=$(echo ${KEEP_IMAGES} | tr "," "\n")
      for x in $arr
      do
          if [ $DEBUG ]; then echo "DEBUG: Identifying image $x"; fi
          docker image inspect $x --format='{{.Id}}' 2>/dev/null >> KeepImageIdList
      done
      sort KeepImageIdList -o KeepImageIdList
      comm -23 ToBeCleanedImageIdList KeepImageIdList > ToBeCleanedImageIdList2
      mv ToBeCleanedImageIdList2 ToBeCleanedImageIdList
    fi

    # Keep volume info image
    docker inspect $VOLUME_INFOS_IMAGE --format='{{.Id}}' 2>/dev/null >> KeepUtilsImageId
    docker inspect $DURATION_IMAGE --format='{{.Id}}' 2>/dev/null >> KeepUtilsImageId
    sort KeepUtilsImageId -o KeepUtilsImageId
    comm -23 ToBeCleaned KeepUtilsImageId > ToBeCleaned2
    mv ToBeCleaned2 ToBeCleaned

    # Remove Images
    removeImages


    echo "=> Removing unused volumes using native 'docker volume' command"
    DANGLING_VOLUMES_IDS="`docker volume ls -qf dangling=true | xargs echo`"
    for VOLUME_ID in $DANGLING_VOLUMES_IDS; do
      keepit=0
      if [ $DEBUG ]; then echo "DEBUG: Check volume $VOLUME_ID"; fi
      if [ ${#VOLUME_ID} -eq 64 ]; then   # TODO: Improve assumption here.  Length of 64 means unnamed?  RegEx match?  https://tldp.org/LDP/Bash-Beginners-Guide/html/sect_10_03.html
        if [ $DEBUG ]; then echo "DEBUG: Volume is unnamed"; fi

        if [ ${KEEP_VOLUMES_UNNAMED} == "true" ]; then
          keepit=1

        elif [ "${KEEP_VOLUMES_ATIME_SINCE}" != "0" ] || [ "${KEEP_VOLUMES_MTIME_SINCE}" != "0" ]; then
          VOLUME_INFOS_JSON="`docker run --rm -v $VOLUME_ID:/volume $VOLUME_INFOS_IMAGE`"
          if [ $DEBUG ]; then echo "DEBUG: Volume infos:"; fi
          if [ $DEBUG ]; then echo "DEBUG: $VOLUME_INFOS_JSON"; fi

          EMPTY="`echo $VOLUME_INFOS_JSON | jq .isEmpty`"

          if [ ${EMPTY} == "true" ]; then
            if [ $DEBUG ]; then echo "DEBUG: Volume is empty"; fi
          else
            ATIME_SINCE_IN_SECONDS="`docker run --rm $DURATION_IMAGE $KEEP_VOLUMES_ATIME_SINCE`"
            LAST_ATIME_SINCE="`echo $VOLUME_INFOS_JSON | jq .lastAccess.since`"
            if [ $DEBUG ]; then echo "DEBUG: Volume last access time was since ${LAST_ATIME_SINCE} seconds."; fi
            if [ "${LAST_ATIME_SINCE}" -gt ${ATIME_SINCE_IN_SECONDS} ]; then
              if [ $DEBUG ]; then echo "DEBUG: This is greater than the given ${ATIME_SINCE_IN_SECONDS} seconds (${KEEP_VOLUMES_ATIME_SINCE}) to keep volumes"; fi
            else
              keepit=1
              if [ $DEBUG ]; then echo "DEBUG: This is less than the given ${ATIME_SINCE_IN_SECONDS} seconds (${KEEP_VOLUMES_ATIME_SINCE}) to keep volumes"; fi
            fi

            MTIME_SINCE_IN_SECONDS="`docker run --rm $DURATION_IMAGE $KEEP_VOLUMES_MTIME_SINCE`"
            LAST_MTIME_SINCE="`echo $VOLUME_INFOS_JSON | jq .lastModify.since`"
            if [ $DEBUG ]; then echo "DEBUG: Volume last modification time was since ${LAST_MTIME_SINCE} seconds."; fi
            if [ "${LAST_MTIME_SINCE}" -gt ${MTIME_SINCE_IN_SECONDS} ]; then
              if [ $DEBUG ]; then echo "DEBUG: This is greater than the given ${MTIME_SINCE_IN_SECONDS} seconds to keep volumes"; fi
            else
              keepit=1
              if [ $DEBUG ]; then echo "DEBUG: This is less than the given ${MTIME_SINCE_IN_SECONDS} seconds (${KEEP_VOLUMES_MTIME_SINCE}) to keep volumes"; fi
            fi
          fi
        fi

      else
        if [ $DEBUG ]; then echo "DEBUG: Volume $VOLUME_ID is named"; fi
        checkPatterns "${KEEP_VOLUMES_NAMED}" "${VOLUME_ID}" $keepit
        keepit=$?
      fi
      if [[ $keepit -eq 0 ]]; then
        echo "Removing dangling volume $VOLUME_ID"
        docker volume rm "${VOLUME_ID}"
      else
        echo "Keeping dangling volume $VOLUME_ID"
      fi
    done
    unset VOLUME_ID


    echo "=> Performing cleanup"
    # Clean
    rm -f ToBeCleanedImageIdList ContainerImageIdList ToBeCleaned ImageIdList KeepImageIdList CreatedContainerIdList CreatedContainerToClean KeepVolumeInfoImageId KeepUtilsImageId

    # Run forever or exit after the first run depending on the value of $LOOP
    [ "${LOOP}" == "true" ] || break


    echo "=> Next clean will be started in ${CLEAN_PERIOD} seconds"
    sleep ${CLEAN_PERIOD} & wait
done
