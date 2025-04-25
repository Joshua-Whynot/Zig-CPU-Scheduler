# Zig-CPU-Scheduler
A simulation for different cpu scheduling modes written in Zig
Only works on Linux at the moment.

To run download Zig version 0.13.0 and run zig build in home directory. After building execute binary in zig/out folder with arguments:
The program will accept a switch `-s` which selects which scheduler to simulate, an optional time quantum `-q` and an input and output filename:

	./schsim -s FF -q 2 input.csv output.csv

The input file will be a `.csv` containing a list of processes, at which CPU cycle they arrive, how many cycles they take to complete and an optional list of I/O times and how many cycles that I/O burst takes:

	"A", 0, 3
	"B", 2, 6
	, 3, 2
	"C", 4, 4
	"D", 6, 5
	"E", 8, 2

Each line in the file will either begin with a `"` character indicating it is a process or a `,` character indicating it is an I/O burst for the preceding process.
