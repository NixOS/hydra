spaceleft=$(($(stat -f -c '%a' /nix/store) * $(stat -f -c '%S' /nix/store)))
spacestopstart() {
  service=$1
  minFreeGB=$2
  if [ $spaceleft -lt $(($minFreeGB * 1024**3)) ]; then
    if [ $(systemctl is-active $service) == active ]; then
      echo "stopping $service due to lack of free space..."
      systemctl stop $service
      date > /var/lib/hydra/.$service-stopped-minspace
    fi
  else
    if [ $spaceleft -gt $(( ($minFreeGB + 10) * 1024**3)) -a \
         -r /var/lib/hydra/.$service-stopped-minspace ] ; then
      rm /var/lib/hydra/.$service-stopped-minspace
      echo "restarting $service due to newly available free space..."
      systemctl start $service
    fi
  fi
}
