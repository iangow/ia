#!/usr/bin/python
import glob
import re
import subprocess
import sys

# print sys.argv
year = sys.argv[1]
print year

path = '/wrds/taq/sasdata/ct_' + str(year) + '*.sas7bdat'
print path
file_list = glob.glob(path)

for daily_file in file_list:
  date = re.sub('/wrds/taq/sasdata/ct_(\d{8}).sas7bdat', '\\1', daily_file)
  command = "time sas ia_daily_idg.sas -log " + date + ".log "
  command += "-noterminal -sysparm \"" + date + "\""
  print command
  subprocess.call(command, shell=True)

print "All done!"
