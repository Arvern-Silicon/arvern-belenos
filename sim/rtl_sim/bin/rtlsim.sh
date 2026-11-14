#!/bin/bash
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    rtlsim
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : rtlsim.sh
# Module Description : RTL simulation driver script.
#----------------------------------------------------------------------------
# Environment:
#   VERILOG_SIMULATOR  iverilog (default) / verilator / cver / verilog /
#                      ncverilog / vcs / vsim
#   SIMULATION_NODUMP  1 = no waveform
#   BLNS_DEFINES       space-separated NAME=VALUE bench defines, e.g.
#                      "BLNS_DIF_TYPE=3 BLNS_ASYNC_RST_EN=0" (see tb_belenos.v)
#----------------------------------------------------------------------------

###############################################################################
#                            Parameter Check                                  #
###############################################################################
EXPECTED_ARGS=3
if [ $# -ne $EXPECTED_ARGS ]; then
  echo "ERROR    : wrong number of arguments"
  echo "USAGE    : rtlsim.sh <verilog stimulus file> <submit file>   <seed>"
  echo "Example  : rtlsim.sh ./stimulus.v            ../../../bench/verilog/submit.f  123"
  echo "VERILOG_SIMULATOR env keeps simulator name iverilog/verilator/cver/verilog/ncverilog/vsim/vcs"
  exit 1
fi


###############################################################################
#                     Check if the required files exist                       #
###############################################################################

if [ ! -e $1 ]; then
    echo "Verilog stimulus file $1 doesn't exist"
    exit 1
fi
if [ ! -e $2 ]; then
    echo "Verilog submit file $2 doesn't exist"
    exit 1
fi


###############################################################################
#               Flatten the submit filelist to absolute paths                 #
###############################################################################
# rtl/verilog/filelist.f uses paths relative to the filelist's own directory.
# flatten_filelist.py walks the -f tree, resolves every entry against its
# containing filelist's dir, and emits one absolute-path flat file safe to pass
# to any simulator regardless of cwd. It is dropped into the cwd as
# submit_sim.f for inspection and overwritten on every run.

FLATTEN_PY="$(dirname "$(realpath "$0")")/flatten_filelist.py"
SUBMIT_F="./submit_sim.f"
"$FLATTEN_PY" "$2" "$SUBMIT_F" >/dev/null

# Bench defines from the environment
IV_DEFS=""
PLUS_DEFS=""
for d in ${BLNS_DEFINES:-}; do
    IV_DEFS="$IV_DEFS -D $d"
    PLUS_DEFS="$PLUS_DEFS +define+$d"
done


###############################################################################
#                         Start verilog simulation                            #
###############################################################################

NODUMP=${SIMULATION_NODUMP-0}

if [ "${VERILOG_SIMULATOR:-iverilog}" = iverilog ]; then

    rm -rf simv

    if [ $NODUMP -eq 1 ]
      then
        iverilog -o simv -c $SUBMIT_F -D SEED=$3 -D NODUMP $IV_DEFS || exit 1
      else
        iverilog -o simv -c $SUBMIT_F -D SEED=$3 $IV_DEFS || exit 1
    fi

    if [[ $(uname -s) == CYGWIN* ]];
    then
     	vvp.exe ./simv
    else
        ./simv
    fi

elif [ "$VERILOG_SIMULATOR" = verilator ]; then

    # Same build as bin/runcov without the coverage instrumentation. The
    # stimulus is `include`d by the bench, hence +incdir+. for stimulus.v.
    rm -rf obj_dir simv
    vargs="+define+SEED=$3 $PLUS_DEFS"
    [ $NODUMP -eq 1 ] && vargs="$vargs +define+NODUMP"
    verilator --binary --timing --x-initial unique \
        -Wno-fatal -Wno-TIMESCALEMOD -Wno-LATCH -Wno-WIDTHEXPAND --quiet-exit \
        $vargs +incdir+. "$(dirname "$(realpath "$0")")/cov_public.vlt" -f $SUBMIT_F \
        --top-module tb_belenos --Mdir obj_dir -o simv > verilator_build.log 2>&1 \
        || { cat verilator_build.log; exit 1; }
    ./obj_dir/simv +verilator+rand+reset+1

else

    if [ $NODUMP -eq 1 ] ; then
       vargs="+define+SEED=$3 +define+NODUMP $PLUS_DEFS"
    else
       vargs="+define+SEED=$3 $PLUS_DEFS"
    fi

   case $VERILOG_SIMULATOR in
    cver* )
       vargs="$vargs +define+VXL +define+CVER" ;;
    verilog* )
       vargs="$vargs +define+VXL" ;;
    ncverilog* )
       rm -rf INCA_libs
       vargs="$vargs +access+r +svseed=$3 +nclicq +define+TRN_FILE" ;;
    vcs* )
       rm -rf csrc simv*
       vargs="$vargs -lca -debug_access+all -sverilog +define+VPD_FILE" ;;
    vsim* )
       # Modelsim
       if [ -d work ]; then  vdel -all; fi
       vlib work
       exec vlog +acc=prn -f $SUBMIT_F $vargs -R -c -do "run -all" ;;
   esac

   echo "Running: $VERILOG_SIMULATOR -f $SUBMIT_F $vargs"
   exec $VERILOG_SIMULATOR -f $SUBMIT_F $vargs
fi
