#!/bin/bash

targetcli <<EOF
/backstores/ramdisk create mptest 10M
/loopback create naa.5001401111111111
/loopback create naa.5001402222222222
/loopback create naa.5001403333333333
/loopback create naa.5001404444444444
/loopback create naa.5001405555555555
/loopback/naa.5001401111111111/luns create /backstores/ramdisk/mptest
/loopback/naa.5001402222222222/luns create /backstores/ramdisk/mptest
/loopback/naa.5001403333333333/luns create /backstores/ramdisk/mptest
/loopback/naa.5001404444444444/luns create /backstores/ramdisk/mptest
/loopback/naa.5001405555555555/luns create /backstores/ramdisk/mptest
EOF
