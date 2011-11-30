#! /bin/sh

action="$1"

if test -z "$HYDRA_DATA"; then
    echo "Error: \$HYDRA_DATA is not set";
    exit 1
fi

if test "$action" = "start"; then

    hydra_server.pl > $HYDRA_DATA/server.log 2>&1 &
    echo $! > $HYDRA_DATA/server.pid

    hydra_evaluator.pl > $HYDRA_DATA/evaluator.log 2>&1 &
    echo $! > $HYDRA_DATA/evaluator.pid

    hydra_queue_runner.pl > $HYDRA_DATA/queue_runner.log 2>&1 &
    echo $! > $HYDRA_DATA/queue_runner.pid

elif test "$action" = "stop"; then

    kill $(cat $HYDRA_DATA/server.pid)
    kill $(cat $HYDRA_DATA/evaluator.pid)
    kill $(cat $HYDRA_DATA/queue_runner.pid)

elif test "$action" = "status"; then

    echo -n "Hydra web server... "
    (kill -0 $(cat $HYDRA_DATA/server.pid) 2> /dev/null && echo "ok") || echo "not running"
    
    echo -n "Hydra evaluator... "
    (kill -0 $(cat $HYDRA_DATA/evaluator.pid) 2> /dev/null && echo "ok") || echo "not running"
    
    echo -n "Hydra queue runner... "
    (kill -0 $(cat $HYDRA_DATA/queue_runner.pid) 2> /dev/null && echo "ok") || echo "not running"
    

else
    echo "Syntax: $0 [start|stop|status]"
    exit 1
fi
