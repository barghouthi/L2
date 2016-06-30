#! /bin/sh

python3 ./specs-aws/dinner.py -c "./l2.native" -f ./specs-aws/benchmarks.txt -o ./specs-aws/$(date +%Y-%m-%d:%H:%M:%S).log --cpu 300 --mem 10000
