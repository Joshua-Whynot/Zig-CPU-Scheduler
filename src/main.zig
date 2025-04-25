const std = @import("std");
const io = std.io;
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const process = std.process; 
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

//process state represents where a process is in the system
const ProcessState = enum {
    arrival, //in the arrival queue
    ready, //in the ready queue
    running, //currently in the CPU
    io_wait, //in the I/O wait queue
    finished, //in the finish queue
};

//IOBurst represents an I/O operation
const IOBurst = struct {
    start_time: usize, //when this I/O burst starts (in remaining CPU time)
    duration: usize, //how long this I/O burst takes
    remaining: usize, //remaining time for this I/O burst
};

//process represents a process in the scheduler
const Process = struct {
    id: []const u8, //process identifier (e.g., "A", "B")
    arrival_time: usize, //when the process arrives
    service_time: usize, //total CPU time needed
    remaining_time: usize, //remaining CPU time needed

    start_time: usize = 0, //when the process first got CPU
    finish_time: usize = 0, //when the process completed
    waiting_time: usize = 0, //total time spent waiting
    quantum_remaining: usize = 0, //for round robin and feedback

    state: ProcessState = .arrival,
    io_bursts: ArrayList(IOBurst),
    current_io_burst: ?IOBurst = null,
    allocator: Allocator, //store allocator to free memory later

    pub fn init(allocator: Allocator, id: []const u8, arrival_time: usize, service_time: usize) !Process {
        return Process{
            .id = id,
            .arrival_time = arrival_time,
            .service_time = service_time,
            .remaining_time = service_time,
            .io_bursts = ArrayList(IOBurst).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Process) void {
        self.allocator.free(self.id); //free the duplicated ID
        self.io_bursts.deinit();
    }

    //process helper functions
    pub fn addIOBurst(self: *Process, start_time: usize, duration: usize) !void {
        try self.io_bursts.append(IOBurst{
            .start_time = start_time,
            .duration = duration,
            .remaining = duration,
        });
    }

    pub fn turnaround_time(self: *const Process) usize {
        return self.finish_time - self.arrival_time;
    }

    pub fn normalized_turnaround_time(self: *const Process) f32 {
        return @as(f32, @floatFromInt(self.turnaround_time())) / @as(f32, @floatFromInt(self.service_time));
    }

    pub fn checkForIO(self: *Process) bool {
        for (self.io_bursts.items) |io_burst| {
            if (self.remaining_time == io_burst.start_time) {
                self.current_io_burst = io_burst;
                return true;
            }
        }
        return false;
    }
};

//the type of scheduler to use
const SchedulerType = enum {
    FF, //first-come-first-served
    RR, //round robin (with settable quantum)
    SP, //shortest process next
    SR, //shortest remaining time
    HR, //highest response ratio next
    FB, //feedback (with settable quantum)
};

//scheduler simulator
const Scheduler = struct {
    allocator: Allocator,
    scheduler_type: SchedulerType,
    quantum: usize,
    verbose: bool,

    current_cycle: usize = 0,
    arrival_queue: ArrayList(*Process),
    ready_queue: ArrayList(*Process),
    io_wait_queue: ArrayList(*Process),
    current_process: ?*Process = null,
    finish_queue: ArrayList(*Process),

    pub fn init(allocator: Allocator, scheduler_type: SchedulerType, quantum: usize, verbose: bool) Scheduler {
        return Scheduler{
            .allocator = allocator,
            .scheduler_type = scheduler_type,
            .quantum = quantum,
            .verbose = verbose,
            .current_cycle = 0,
            .arrival_queue = ArrayList(*Process).init(allocator),
            .ready_queue = ArrayList(*Process).init(allocator),
            .io_wait_queue = ArrayList(*Process).init(allocator),
            .finish_queue = ArrayList(*Process).init(allocator),
        };
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.arrival_queue.items) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.arrival_queue.deinit();
        self.ready_queue.deinit();
        self.io_wait_queue.deinit();
        self.finish_queue.deinit();
    }

    //add a process to the arrival queue - fixed parameter name to avoid shadowing
    pub fn addProcess(self: *Scheduler, proc_ptr: *Process) !void {
        try self.arrival_queue.append(proc_ptr);
    }

    //select next process from ready queue based on scheduler type
    pub fn select(self: *Scheduler) ?*Process {
        if (self.ready_queue.items.len == 0) return null;

        var selected_idx: usize = 0;
        var selected_process = self.ready_queue.items[0];

        switch (self.scheduler_type) {
            //first-come-first-served (already sorted by arrival time)
            .FF => {},

            //round robin (already handled by cycle())
            .RR => {},

            //shortest process next
            .SP => {
                var shortest_time = selected_process.service_time;
                for (self.ready_queue.items, 0..) |p, i| {
                    if (p.service_time < shortest_time) {
                        shortest_time = p.service_time;
                        selected_idx = i;
                        selected_process = p;
                    }
                }
            },

            //shortest remaining time
            .SR => {
                var shortest_remaining = selected_process.remaining_time;
                for (self.ready_queue.items, 0..) |p, i| {
                    if (p.remaining_time < shortest_remaining) {
                        shortest_remaining = p.remaining_time;
                        selected_idx = i;
                        selected_process = p;
                    }
                }
            },

            //highest response ratio next
            .HR => {
                var highest_ratio: f32 = (@as(f32, @floatFromInt(selected_process.waiting_time)) + @as(f32, @floatFromInt(selected_process.service_time))) /
                    @as(f32, @floatFromInt(selected_process.service_time));
                for (self.ready_queue.items, 0..) |p, i| {
                    const ratio = (@as(f32, @floatFromInt(p.waiting_time)) + @as(f32, @floatFromInt(p.service_time))) /
                        @as(f32, @floatFromInt(p.service_time));
                    if (ratio > highest_ratio) {
                        highest_ratio = ratio;
                        selected_idx = i;
                        selected_process = p;
                    }
                }
            },

            //feedback (already handled by cycle())
            .FB => {},
        }

        _ = self.ready_queue.orderedRemove(selected_idx);
        return selected_process;
    }

    //sort processes in the arrival queue by arrival time
    pub fn sortArrivalQueue(self: *Scheduler) void {
        std.sort.block(*Process, self.arrival_queue.items, {}, struct {
            fn lessThan(_: void, a: *Process, b: *Process) bool {
                return a.arrival_time < b.arrival_time;
            }
        }.lessThan);
    }

    fn sortReadyQueueFF(self: *Scheduler) void {
        if (self.scheduler_type != .FF) return;

        //sort the ready queue by arrival time to maintain FCFS order
        std.sort.block(*Process, self.ready_queue.items, {}, struct {
            fn lessThan(_: void, a: *Process, b: *Process) bool {
                return a.arrival_time < b.arrival_time;
            }
        }.lessThan);
    }

    //one cycle of the CPU
    pub fn cycle(self: *Scheduler) !void {
        //move processes from arrival queue to ready queue if their arrival time matches
        var i: usize = 0;
        while (i < self.arrival_queue.items.len) {
            const p = self.arrival_queue.items[i];
            if (p.arrival_time == self.current_cycle) {
                p.state = .ready;
                _ = self.arrival_queue.orderedRemove(i);
                try self.ready_queue.append(p);
                self.sortReadyQueueFF();
            } else {
                i += 1;
            }
        }

        //check I/O wait queue
        i = 0;
        while (i < self.io_wait_queue.items.len) {
            var p = self.io_wait_queue.items[i];
            if (p.current_io_burst) |*io_burst| {
                io_burst.remaining -= 1;
                if (io_burst.remaining == 0) {
                    p.current_io_burst = null;
                    p.state = .ready;
                    _ = self.io_wait_queue.orderedRemove(i);
                    try self.ready_queue.append(p);
                    self.sortReadyQueueFF();
                } else {
                    i += 1;
                }
            }
        }

        //handle current running process
        if (self.current_process) |proc| {
            proc.remaining_time -= 1;

            if (proc.remaining_time == 0) {
                //process has finished
                proc.state = .finished;
                proc.finish_time = self.current_cycle;
                try self.finish_queue.append(proc);
                self.current_process = null;
            } else if (proc.checkForIO()) {
                //process needs I/O
                proc.state = .io_wait;
                try self.io_wait_queue.append(proc);
                self.current_process = null;
            } else if (self.scheduler_type == .RR and proc.quantum_remaining > 0) {
                proc.quantum_remaining -= 1;
                if (proc.quantum_remaining == 0) {
                    //quantum expired, put process back in ready queue
                    proc.state = .ready;
                    proc.quantum_remaining = self.quantum;
                    try self.ready_queue.append(proc);
                    self.current_process = null;
                }
            } else if (self.scheduler_type == .FB) {
                proc.quantum_remaining -= 1;
                if (proc.quantum_remaining == 0) {
                    //quantum expired, put process back in ready queue with lower priority
                    proc.state = .ready;
                    try self.ready_queue.append(proc);
                    self.current_process = null;
                }
            } else if (self.scheduler_type == .SR) {
                //check if there's a process with shorter remaining time
                for (self.ready_queue.items) |ready_proc| {
                    if (ready_proc.remaining_time < proc.remaining_time) {
                        proc.state = .ready;
                        try self.ready_queue.append(proc);
                        self.current_process = null;
                        break;
                    }
                }
            }
        }

        //if CPU is idle, select a new process
        if (self.current_process == null and self.ready_queue.items.len > 0) {
            const next_process = self.select();
            if (next_process) |proc| {
                proc.state = .running;
                if (proc.service_time == proc.remaining_time) {
                    proc.start_time = self.current_cycle;
                }

                if (self.scheduler_type == .RR) {
                    proc.quantum_remaining = self.quantum;
                } else if (self.scheduler_type == .FB) {
                    //for FB, quantum is either 1 or 2 based on input
                    proc.quantum_remaining = if (self.quantum == 1) 1 else @as(usize, 1) << @intCast((proc.service_time - proc.remaining_time) / proc.service_time);
                }

                self.current_process = proc;
            }
        }

        //increment waiting time for processes in ready queue
        for (self.ready_queue.items) |p| {
            p.waiting_time += 1;
        }

        //increment cycle
        self.current_cycle += 1;
    }

    //print the current state of the scheduler if verbose mode is enabled
    pub fn printVerboseState(self: *const Scheduler, writer: anytype) !void {
        if (!self.verbose) return;

        //get all process IDs
        var processes = ArrayList(*const Process).init(self.allocator);
        defer processes.deinit();

        for (self.arrival_queue.items) |p| {
            try processes.append(p);
        }
        for (self.ready_queue.items) |p| {
            try processes.append(p);
        }
        for (self.io_wait_queue.items) |p| {
            try processes.append(p);
        }
        if (self.current_process) |p| {
            try processes.append(p);
        }
        for (self.finish_queue.items) |p| {
            try processes.append(p);
        }

        //sort processes by ID
        std.sort.block(*const Process, processes.items, {}, struct {
            fn lessThan(_: void, a: *const Process, b: *const Process) bool {
                return mem.lessThan(u8, a.id, b.id);
            }
        }.lessThan);

        //if this is the first cycle (0), print the header
        if (self.current_cycle - 1 == 0) {
            try writer.print("     |", .{});
            for (processes.items) |p| {
                try writer.print(" {s} |", .{p.id});
            }
            try writer.print("\n", .{});
        }

        //print the current cycle number
        try writer.print(" {:3}:", .{self.current_cycle - 1});

        //print the process states (# for running, empty for other states)
        for (processes.items) |p| {
            var state_char: []const u8 = " ";
            if (self.current_process) |running| {
                if (mem.eql(u8, p.id, running.id)) {
                    state_char = "#";
                }
            }
            try writer.print("  {s} ", .{state_char});
        }

        //print the queue contents
        try writer.print("|", .{});
        if (self.arrival_queue.items.len > 0) {
            try writer.print(" arrival = {{", .{});
            var first = true;
            for (self.arrival_queue.items) |p| {
                if (!first) try writer.print(", ", .{});
                try writer.print("{s}", .{p.id});
                first = false;
            }
            try writer.print("}}", .{});
        }

        if (self.ready_queue.items.len > 0) {
            try writer.print(" ready = {{", .{});
            var first = true;
            for (self.ready_queue.items) |p| {
                if (!first) try writer.print(", ", .{});
                try writer.print("{s}", .{p.id});
                first = false;
            }
            try writer.print("}}", .{});
        }

        if (self.io_wait_queue.items.len > 0) {
            try writer.print(" io = {{", .{});
            var first = true;
            for (self.io_wait_queue.items) |p| {
                if (!first) try writer.print(", ", .{});
                try writer.print("{s}", .{p.id});
                first = false;
            }
            try writer.print("}}", .{});
        }

        try writer.print("\n", .{});
    }

    //run the simulation until all processes are finished
    pub fn run(self: *Scheduler, writer: anytype) !void {
        self.sortArrivalQueue();

        while (self.arrival_queue.items.len > 0 or
            self.ready_queue.items.len > 0 or
            self.io_wait_queue.items.len > 0 or
            self.current_process != null)
        {
            try self.cycle();
            try self.printVerboseState(writer);
        }
    }

    //write results to the output file
    pub fn writeResults(self: *const Scheduler, filePath: []const u8) !void {
        //prepare to write to output file
        const file = try fs.cwd().createFile(filePath, .{});
        defer file.close(); //defer cleanup
        const writer = file.writer();

        //print header
        try writer.print("\"name\", \"arrival time\", \"service time\", \"start time\", \"total wait time\", \"finish time\", \"turnaround time\", \"normalized turnaround\"\n", .{});

        //sort processes by start time for output
        var sorted_processes = ArrayList(*const Process).init(self.allocator);
        defer sorted_processes.deinit();

        for (self.finish_queue.items) |p| {
            try sorted_processes.append(p);
        }

        //sort processes by finish time
        std.sort.block(*const Process, sorted_processes.items, {}, struct {
            fn lessThan(_: void, a: *const Process, b: *const Process) bool {
                return a.finish_time < b.finish_time;
            }
        }.lessThan);

        //calculate sums for averages
        var total_turnaround: f32 = 0.0;
        var total_normalized: f32 = 0.0;

        //write each process's stats
        for (sorted_processes.items) |p| {
            const wait_time = p.finish_time - p.arrival_time - p.service_time;
            const turnaround = p.finish_time - p.arrival_time;
            const normalized = @as(f32, @floatFromInt(turnaround)) / @as(f32, @floatFromInt(p.service_time));

            try writer.print("\"{s}\", {}, {}, {}, {}, {}, {}, {d:.2}\n", .{ p.id, p.arrival_time, p.service_time, p.start_time, wait_time, p.finish_time, turnaround, normalized });

            total_turnaround += @floatFromInt(turnaround);
            total_normalized += normalized;
        }

        //write averages
        const avg_turnaround = total_turnaround / @as(f32, @floatFromInt(sorted_processes.items.len));
        const avg_normalized = total_normalized / @as(f32, @floatFromInt(sorted_processes.items.len));

        try writer.print("{d:.2}, {d:.2}\n", .{ avg_turnaround, avg_normalized });
    }
};

//define error set for argument parsing
const ArgsError = error{
    MissingQuantumValue,
    InvalidSchedulerType,
    MissingSchedulerType,
    MissingInputFilePath,
    MissingOutputFilePath,
};

//parse command line arguments
fn parseArgs() !struct {
    scheduler_type: SchedulerType,
    quantum: usize,
    verbose: bool,
    input_path: []const u8,
    output_path: []const u8,
} {
    var args_iter = process.args();
    //skip program name
    _ = args_iter.next();

    //collect all arguments into an array for easier processing
    var args = ArrayList([]const u8).init(std.heap.page_allocator);
    defer args.deinit();

    while (args_iter.next()) |arg| {
        try args.append(arg);
    }

    //we need at least two arguments (input and output file)
    if (args.items.len < 2) {
        return ArgsError.MissingInputFilePath;
    }

    //extract the input and output paths (last two arguments)
    const input_path = args.items[args.items.len - 2];
    const output_path = args.items[args.items.len - 1];

    //remove the input and output paths from the list to process the remaining flags
    _ = args.pop(); //remove output path
    _ = args.pop(); //remove input path

    var scheduler_type: SchedulerType = .FF;
    var quantum: usize = 0;
    var verbose: bool = false;

    //process the remaining flags
    var i: usize = 0;
    while (i < args.items.len) {
        const arg = args.items[i];

        if (mem.eql(u8, arg, "-v")) {
            verbose = true;
            i += 1;
        } else if (mem.eql(u8, arg, "-q")) {
            if (i + 1 < args.items.len) {
                quantum = try fmt.parseInt(usize, args.items[i + 1], 10);
                i += 2;
            } else {
                return ArgsError.MissingQuantumValue;
            }
        } else if (mem.eql(u8, arg, "-s")) {
            //if switch for scheduler type is enable grab our scheduler type
            if (i + 1 < args.items.len) {
                const s = args.items[i + 1];
                if (mem.eql(u8, s, "FF")) {
                    scheduler_type = .FF;
                } else if (mem.eql(u8, s, "RR")) {
                    scheduler_type = .RR;
                } else if (mem.eql(u8, s, "SP")) {
                    scheduler_type = .SP;
                } else if (mem.eql(u8, s, "SR")) {
                    scheduler_type = .SR;
                } else if (mem.eql(u8, s, "HR")) {
                    scheduler_type = .HR;
                } else if (mem.eql(u8, s, "FB")) {
                    scheduler_type = .FB;
                } else {
                    return ArgsError.InvalidSchedulerType;
                }
                i += 2;
            } else {
                return ArgsError.MissingSchedulerType;
            }
        } else {
            //skip unknown arguments
            i += 1;
        }
    }

    return .{
        .scheduler_type = scheduler_type,
        .quantum = quantum,
        .verbose = verbose,
        .input_path = input_path,
        .output_path = output_path,
    };
}

//parse the input from a file
fn parseInputFile(allocator: Allocator, filePath: []const u8) !ArrayList(*Process) {
    var processes = ArrayList(*Process).init(allocator);
    errdefer { //defer cleanup if error occurs
        for (processes.items) |p| {
            p.deinit();
            allocator.destroy(p);
        }
        processes.deinit();
    }

    //open the file
    const file = try fs.cwd().openFile(filePath, .{});
    defer file.close(); //defer cleanup
    const reader = file.reader();
    var line = ArrayList(u8).init(allocator);
    defer line.deinit(); //defer cleanup

    //track current process incase I/O burst is next
    var current_process: ?*Process = null;

    //read line by line
    while (true) {
        //reset line buffer
        line.clearRetainingCapacity();

        reader.streamUntilDelimiter(line.writer(), '\n', 1024) catch |err| {
            if (err == error.EndOfStream) {
                break; //end of file reached
            } else {
                return err; //return any other error
            }
        };

        //skip empty lines
        const trimmed_line = std.mem.trim(u8, line.items, " \t\r\n");
        if (line.items.len == 0 or trimmed_line.len == 0) {
            continue;
        }

        //split the line by commas
        var parts = std.mem.split(u8, line.items, ",");

        const first_part = parts.next() orelse continue;
        const trimmed_first = std.mem.trim(u8, first_part, " \t\r\n\"");

        if (trimmed_first.len > 0) {
            //line starts with a process ID - this is a new process
            const id = try allocator.dupe(u8, trimmed_first);

            //get arrival time
            const arrival_str = parts.next() orelse return error.InvalidFormat;
            const trimmed_arrival = std.mem.trim(u8, arrival_str, " \t\r\n");
            if (trimmed_arrival.len == 0) return error.InvalidFormat;
            const arrival_time = try fmt.parseInt(usize, trimmed_arrival, 10);

            //get service time
            const service_str = parts.next() orelse return error.InvalidFormat;
            const trimmed_service = std.mem.trim(u8, service_str, " \t\r\n");
            if (trimmed_service.len == 0) return error.InvalidFormat;
            const service_time = try fmt.parseInt(usize, trimmed_service, 10);

            //create the process
            const process_ptr = try allocator.create(Process);
            process_ptr.* = try Process.init(allocator, id, arrival_time, service_time);

            //add to the list
            try processes.append(process_ptr);
            current_process = process_ptr;
        } else {
            //line starts with a comma - this is an I/O burst for the previous process
            if (current_process == null) { //make sure we arent getting an io burst at the start of the file
                return error.IoWithoutProcess;
            }

            //get start time for I/O burst
            const start_str = parts.next() orelse return error.InvalidFormat;
            const trimmed_start = std.mem.trim(u8, start_str, " \t\r\n");
            if (trimmed_start.len == 0) return error.InvalidFormat;
            const start_time = try fmt.parseInt(usize, trimmed_start, 10);

            //get duration for I/O burst
            const duration_str = parts.next() orelse return error.InvalidFormat;
            const trimmed_duration = std.mem.trim(u8, duration_str, " \t\r\n");
            if (trimmed_duration.len == 0) return error.InvalidFormat;
            const duration = try fmt.parseInt(usize, trimmed_duration, 10);

            //add the I/O burst to the current process
            try current_process.?.addIOBurst(start_time, duration);
        }
    }
    return processes;
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    //parse command line args
    const args = try parseArgs();
    //grab input file from path
    const processes = try parseInputFile(allocator, args.input_path);
    defer { //cleanup later
        for (processes.items) |p| {
            p.deinit();
            allocator.destroy(p);
        }
        processes.deinit();
    }

    //make our scheduler
    var scheduler = Scheduler.init(allocator, args.scheduler_type, args.quantum, args.verbose);
    defer scheduler.deinit();

    //add all processes to scheduler
    for (processes.items) |p| {
        try scheduler.addProcess(p);
    }

    //run the simulation, output to stdout if verbose
    if (args.verbose) {
        const stdout = std.io.getStdOut().writer();
        try scheduler.run(stdout);
    } else {
        try scheduler.run(io.null_writer);
    }

    //dump results to output file
    try scheduler.writeResults(args.output_path);
}
