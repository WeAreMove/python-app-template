alias awkuniq='awk -F":" "{ if (!map[\$1]++) { print \$1 } }"'
