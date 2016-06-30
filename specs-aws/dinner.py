import argparse
import resource as r
import subprocess
import csv
import datetime
import time
import tempfile

def parse_args():
    # constructs the command-line interface for this script
    parser = argparse.ArgumentParser("Helpful benchmarking script")
    parser.add_argument("--cpu", metavar="CPU", type=int, help="CPU limit", default=60)
    parser.add_argument("--mem", metavar="MEM", type=int, help="Mem limit", default=8000)
    parser.add_argument("--prefix", default="DINNER_STAT", help="prefix for stats")
    parser.add_argument("-f", "--file", required=True, help="Input file, test configs per line")
    parser.add_argument("-c", "--command", required=True, help="command to be executed")
    parser.add_argument("-o", "--output", default="output.log", help="location to store output file")
    return parser.parse_args()

def construct_limiter(cpu, mem):
    # creates a function to pass to subprocess commands for limiting exec time
    def limiter():
        if mem > 0:
            bytes = mem * 1024 * 1024
            r.setrlimit(r.RLIMIT_AS, [bytes, bytes])
        if cpu > 0:
            r.setrlimit(r.RLIMIT_CPU, [cpu, cpu])
    return limiter

def construct_runner(command, limiter, prefix):
    # creates the function that executes the command
    def run(line):
        # split config line into name + args*
        name, *args = line.split()
        # store the current CPU usage of child processes
        # includes the usage of starting up a new python process, unfortunately
        old_time = r.getrusage(r.RUSAGE_CHILDREN)[0]
        # try to execute command in separate process
        try:
            result = subprocess.check_output([command] + ["synth"] + args, preexec_fn=limiter)
        except subprocess.CalledProcessError as e:
            result = e.output
        # construct output dict with default column
        output = {"cpu" : r.getrusage(r.RUSAGE_CHILDREN)[0] - old_time, "name" : name}
        # result is a binary string, so we decode
        for entry in result.decode('utf-8').split('\n'):
            # get last instance of every prefixed line
            if entry.startswith(prefix):
                vals = entry.split()
                output[vals[1]] = " ".join(vals[2:]).strip()
        return output
    return run

def write_results(dicts, filename):
    # writes result dicts to output file as csv
    # we first gather all possible columns
    keys = set()
    for d in dicts:
        keys.update(d.keys())
    keys = sorted(keys)
    # start file writing, with column headers
    with open(filename, 'w') as f:
        writer = csv.writer(f)
        writer.writerow(keys)
        # then with all values
        for d in dicts:
            row = []
            for k in keys:
                try:
                    row.append(d[k])
                except KeyError:
                    row.append(None)
            writer.writerow(row)

if __name__ == "__main__":
    # parse args and construct functions
    args = parse_args()
    limiter = construct_limiter(args.cpu, args.mem)
    runner = construct_runner(args.command, limiter, args.prefix)
    # loop over all config lines and gather results
    results = []
    with open(args.file, 'r') as f:
        for line in f.readlines():
            results.append(runner(line))
    # write results and stuff
    write_results(results, args.output)
