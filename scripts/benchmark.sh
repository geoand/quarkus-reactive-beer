#!/bin/bash

HYPERFOIL_HOME=./hyperfoil

URL=beer

DURATION=40

EVENT=cpu

# this can be html or jfr
FORMAT=html

THREADS=2

RATE=0

CONNECTIONS=10

PERF=false

AP=false

NATIVE=false

Help()
{
   # Display Help
   echo "Syntax: benchmark [OPTIONS]"
   echo "options:"
   echo ""
   echo "-h    Display this guide."
   echo ""
   echo "-u    Final part of the URL to benchmark using a vanilla HTTP 1.1 GET request type."
   echo "      e.g. benchmark -u abc would benchmark http://localhost:8080/abc"
   echo "      default is ${URL}"
   echo ""
   echo "-n    Execute the load generation test using native image located in the default path"
   echo "      default is disabled"
   echo ""
   echo "-e    event to profile, if supported e.g. -e cpu "
   echo "      check https://github.com/jvm-profiling-tools/async-profiler#profiler-options for the complete list"
   echo "      default is ${EVENT}"
   echo ""
   echo "-f    output format, if supported by the profiler. e.g. async-profiler support html,jfr,collapsed"
   echo "      default is ${FORMAT}"
   echo ""
   echo "-d    duration of the load generation phase, in seconds"
   echo "      default is ${DURATION} seconds"
   echo ""
   echo "-a    if specified, it uses async-profiler profiling. It works only with JIT mode"
   echo "      disabled by default"
   echo ""
   echo "-t    number of I/O threads of the quarkus application and load generator."
   echo "      default is ${THREADS}"
   echo ""
   echo "-c    number of connections used by the load generator."
   echo "      default is ${CONNECTIONS}"
   echo ""
   echo "-p    if specified, run perf stat together with the selected profiler. Only GNU Linux."
   echo "      disabled by default"
}

while getopts "hu:e:f:d:t:c:pna" option; do
   case $option in
      h) Help
         exit;;
      u) URL=${OPTARG}
         ;;
      e) EVENT=${OPTARG}
         ;;
      f) FORMAT=${OPTARG}
         ;;
      d) DURATION=${OPTARG}
         ;;
      t) THREADS=${OPTARG}
         ;;
      c) CONNECTIONS=${OPTARG}
         ;;
      p) PERF=true
         ;;
      n) NATIVE=true
         ;;
      a) AP=true
         ;;
   esac
done

WARMUP=$((${DURATION}*2/5))

PROFILING=$((${DURATION}/2))

FULL_URL=http://localhost:8080/${URL}

echo "----- Benchmarking endpoint ${FULL_URL}"

# set sysctl kernel variables only if necessary
if [ "${AP}" = true ]; then
  if [[ "$OSTYPE" == "linux-gnu" ]]; then
    current_value=$(sysctl -n kernel.perf_event_paranoid)
    if [ "$current_value" -ne 1 ]; then
      sudo sysctl kernel.perf_event_paranoid=1
      sudo sysctl kernel.kptr_restrict=0
    fi
  fi
fi

trap 'echo "cleaning up quarkus process";kill ${quarkus_pid}' SIGINT SIGTERM SIGKILL

if [ "${NATIVE}" = true ]; then
  ../target/quarkus-reactive-beer-1.0.0-SNAPSHOT-runner -Dquarkus.vertx.event-loops-pool-size=${THREADS} &
else
  java ${JFR_ARGS} -Dquarkus.vertx.event-loops-pool-size=${THREADS} -XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints -jar ../target/quarkus-app/quarkus-run.jar &
fi
quarkus_pid=$!

sleep 2

echo "----- Quarkus running at pid $quarkus_pid using ${THREADS} I/O threads"

echo "----- Start all-out test and profiling"
${HYPERFOIL_HOME}/bin/wrk.sh -c ${CONNECTIONS} -t ${THREADS} -d ${DURATION}s ${FULL_URL} &

wrk_pid=$!

echo "----- Waiting $WARMUP seconds before collecting pid stats"

sleep $WARMUP

NOW=$(date "+%y%m%d_%H_%M_%S")

if [ "${AP}" = true ]; then
  echo "----- Starting async-profiler on quarkus application ($quarkus_pid)"
  java -jar ap-loader-all.jar profiler -e ${EVENT} -t -d ${PROFILING} -f ${NOW}_${EVENT}.${FORMAT} $quarkus_pid &
  ap_pid=$!
fi

if [ "${PERF}" = true ]; then
  echo "----- Collecting perf stat on $quarkus_pid"
  perf stat -d -p $quarkus_pid &
  stat_pid=$!
fi

echo "----- Showing stats for $WARMUP seconds"

if [[ "$OSTYPE" == "linux-gnu" ]]; then
  pidstat -p $quarkus_pid 1 &
  pidstat_pid=$!
  sleep $WARMUP
  kill -SIGTERM $pidstat_pid
else
  # Print stats header
  ps -p $quarkus_pid -o %cpu,rss,vsz | head -1
  sleep 1;
  # Print stats
  for (( i=1; i<$WARMUP; i++ )); do ps -p $quarkus_pid -o %cpu,rss,vsz | tail -1;sleep 1;done;
fi

echo "----- Stopped stats, waiting load to complete"

if [ "${AP}" = true ]; then
  wait $ap_pid
fi

if [ "${PERF}" = true ]; then
  kill -SIGINT $stat_pid
fi

wait $wrk_pid

echo "----- Profiling and workload completed: killing server"

kill -SIGTERM $quarkus_pid
