libname pwd '.';

data pwd.lambda_all;
  set pwd.lambdadaily20:;
run;

proc export data=pwd.lambda_all
  outfile="./lambda_all.csv" dbms=csv replace;
run;
