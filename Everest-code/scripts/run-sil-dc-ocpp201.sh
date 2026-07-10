#!/bin/bash
LD_LIBRARY_PATH=/home/everest/everest-core/build/dist/lib:$LD_LIBRARY_PATH \
PATH=/home/everest/everest-core/build/dist/bin:$PATH \
manager \
    --prefix /home/everest/everest-core/build/dist \
    --conf /home/everest/everest-core/config/config-sil-dc-ocpp201.yaml \
    \
    $@
