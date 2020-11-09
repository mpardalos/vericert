#! /bin/bash 

top=$(pwd)
 #set up
while read benchmark ; do
   echo "Running "$benchmark
   gcc $benchmark.c -o $benchmark.o
   ./$benchmark.o
   cresult=$(echo $?)
   echo "C output: "$cresult
   ../../bin/vericert --debug-hls $benchmark.c -o $benchmark.v
   iverilog -o $benchmark.iver -- $benchmark.v
   ./$benchmark.iver > $benchmark.tmp
   veriresult=$(tail -1 $benchmark.tmp | cut -d' ' -f2)
   cycles=$(tail -4 $benchmark.tmp | head -1 | tr -s ' ' | cut -d' ' -f3)
   echo "Veri output: "$veriresult
   if [ $cresult -ne $veriresult ] 
   then 
   echo "FAIL"
   exit 0 
   else 
   echo "PASS"
   fi
   echo $cycles > $benchmark.cycle
done < benchmark-list-master
