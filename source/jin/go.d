module jin.go;

import core.thread;
import core.atomic;
import core.time;
import std.stdio;
import std.range;
import std.exception;
import std.typecons;
import std.traits;
import std.algorithm;
import std.parallelism;
import std.concurrency;
import std.variant;
import std.string;
import des.ts;

/// Binds args to delegate that calls function with moving args to it.
auto delegateWithMovedArgs(CALLABLE, ARGS...)(auto ref CALLABLE callable, ref ARGS args)
{
	struct TARGS
	{
		ARGS expand;
	}

	enum maxTaskParameterSize = 128;

	static assert(TARGS.sizeof <= maxTaskParameterSize,
			"The arguments must not exceed " ~ maxTaskParameterSize.to!string
			~ " bytes in total size.");

	struct TaskFuncInfo
	{
		void[maxTaskParameterSize] args = void;

		@property ref A typedArgs(A)()
		{
			static assert(A.sizeof <= args.sizeof);
			return *cast(A*) args.ptr;
		}

	}

	TaskFuncInfo tfi;
	foreach (i, A; ARGS)
	{
		args[i].move(tfi.typedArgs!TARGS.expand[i]);
	}

	string callWithMove(ARGS...)(string func, string args)
	{
		import std.string : format;

		string ret = "return " ~ func ~ "(";
		foreach (i, T; ARGS)
		{
			if (i > 0)
				ret ~= ", ";
			ret ~= format("%s[%s].move", args, i);
		}
		return ret ~ ");";
	}

	return {
		TARGS args2;
		tfi.typedArgs!TARGS.move(args2);

		mixin(callWithMove!ARGS("callable", "args2.expand"));
	};
}

/// Yields while condition is `0`.
auto await(Result)(lazy Result check)
{
	for (;;)
	{
		auto value = check;
		if (value != 0)
		{
			return value;
		}
		//Fiber.yield;
	}
}

/// Safe to transfer between threads: shared, immutable, non-copiable
template IsSafeToTransfer(Value)
{
	enum IsSafeToTransfer = !hasUnsharedAliasing!Value || !__traits(compiles, {
			Value x, y = x;
		});
}

/// Run function asynchronously
auto go(alias func, Args...)(auto ref Args args)
		if (is(ReturnType!func : void) && (Parameters!func.length == Args.length))
{
	foreach (i, Arg; Args)
	{
		static assert(IsSafeToTransfer!Arg,
				"Value of type (" ~ Arg.stringof
				~ ") is not safe to pass between threads. Make it immutable or shared!");
	}

	auto task = delegateWithMovedArgs(&func, args).task;

	taskPool.put(task);

	return task;
}

/// Run function asynchronously and return Queue connectetd with range returned by function
auto go(alias func, Args...)(auto ref Args args)
		if (isInputRange!(ReturnType!func))
{
	alias Result = ReturnType!func;
	alias Message = ElementType!Result;

	Input!Message future;

	static void wrapper(Output!Message future, Result function(Args) func, Args args)
	{
		func(args).copy(&future);
	}

	go!wrapper( future.pair , &func , args);

	return future.release;
}

/// Run function with autocreated result Queue and return this Queue
auto go( alias task , Args... )( auto ref Args args )
if( ( Parameters!task.length == Args.length + 1 )&&( is( Parameters!task[0] == Output!Message , Message ) ) )
{
	Parameters!task[0] results;
	auto future = results.pair;
	go!task( results , args );
	return future;
}

/// Cut and return head from input range;
auto next(Range)(auto ref Range range) if (isInputRange!Range)
{
	auto value = range.front;
	range.popFront;
	return value;
}

/// Put to output range
auto next(Range, Value)(auto ref Range range, Value value)
		if (isOutputRange!(Range, Value))
{
	return range.put(value);
}

/// Wait-free one input one output queue
class Queue(Message)
{
	/// No more messages will be produced
	bool closed;

	/// Offset of first not received message
	shared size_t tail;

	/// Cyclic buffer of transferring messages
	Message[] messages;

	/// Offset of next free slot for message
	shared size_t head;

	/// Limit Queue to 8192B by default
	this(int size = ( 8192 - Queue.sizeof ) / Message.sizeof)
	{
		enforce(size > 0, "Queue size must be greater then 0");

		this.messages = new Message[size + 1];
	}

	/// Maximum transferring messages count at one time
	auto size()
	{
		return this.messages.length - 1;
	}

	/// Count of messages in buffer now
	auto pending()
	out (res)
	{
		assert(res >= 0);
	}
	body
	{
		auto len = this.messages.length;
		return (len - this.tail + this.head) % len;
	}

	/// Count of messages that can be sended before buffer will be full
	size_t available()
	out (res)
	{
		assert(res >= 0);
	}
	body
	{
		return this.size - this.pending;
	}

	/// Put message to head
	Value put(Value)(Value value)
	{
		//static assert( isWeaklyIsolated!Value , "Argument type " ~ Value.stringof ~ " is not safe to pass between threads." ); 

		this.messages[this.head] = value;
		atomicStore!(MemoryOrder.rel)(this.head, (this.head + 1) % this.messages.length);

		return value;
	}

	/// Create and put message to head
	/+Value put( Value , Args... )( Args args )
	{
		return this.put( Value( args ) );
	}+/

	/// Get message at tail
	auto front()
	{
		return this.messages[this.tail];
	}

	/// Remove message from tail
	auto popFront()
	{
		atomicStore!(MemoryOrder.rel)(this.tail, (this.tail + 1) % this.messages.length);
	}
}

/// Common Queue collections realization
mixin template Channel(Message)
{
	/// All registered Queues
	Queue!Message[] queues;

	/// Offset of current Queue
	private size_t current;

	/// Make new registered Queue and returns Complement
	auto pair(Args...)(Args args)
	{
		auto queue = new Queue!Message(args);
		this.queues ~= queue;

		Complement!Message complement;
		complement.queues ~= queue;

		return complement;
	}

	// Move queues on channel assigning
	void opAssign(DonorMessage)(ref Channel!DonorMessage donor)
			if (is(DonorMessage : Message))
	{
		this.destroy;
		this.queues = donor.queues;
		this.current = donor.current;
		donor.queues = null;
	}

	auto release()
	{
		alias Self = typeof(this);
		auto rVal = Self();
		rVal.queues = this.queues;
		this.queues = [];
		return rVal;
	}

	/// Close all queues on destroy
	void end()
	{
		foreach (queue; this.queues)
			queue.closed = true;
		this.queues = null;
	}

	~this()
	{
		this.end;
	}

	/// Prevent cloning
	@disable this(this);
}

/// Round robin output channel
struct Output(Message)
{
	alias Complement = Input;

	mixin Channel!Message;

	/// No more messages can be transferred now
	auto available()
	{
		ptrdiff_t available = -1;
		if (this.queues.length == 0)
			return available;

		auto start = this.current;
		do
		{
			auto queue = this.queues[this.current];

			if (!queue.closed)
			{
				available = queue.available;
				if (available > 0)
					return available;
			}

			this.current = (this.current + 1) % this.queues.length;
		}
		while (this.current != start);

		return available;
	}

	/// Put message to current non full Queue and switch Queue
	Value put(Value)(Value value)
	{
		auto available = await(this.available);
		enforce(available != -1, "Can not put to empty Output");

		auto message = this.queues[this.current].put(value);
		this.current = (this.current + 1) % this.queues.length;
		return message;
	}
}

/// Round robin input channel
struct Input(Message)
{
	alias Complement = Output;

	mixin Channel!Message;

	/// Minimum count of pending messages
	auto pending()
	{
		ptrdiff_t pending = -1;
		if (this.queues.length == 0)
			return pending;

		auto start = this.current;
		do
		{
			auto queue = this.queues[this.current];

			auto pending2 = queue.pending;
			if (pending2 > 0)
				return pending2;

			if (!queue.closed)
				pending = 0;

			this.current = (this.current + 1) % this.queues.length;
		}
		while (this.current != start);

		return pending;
	}

	auto empty()
	{
		return this.pending == -1;
	}

	/// Get message at tail of current non clear Queue or wait
	auto front()
	{
		auto pending = await(this.pending);
		enforce(pending > 0 , "Can not get front from empty closed channel");

		return this.queues[this.current].front;
	}

	/// Remove message from tail of current Queue and switch to another Queue
	void popFront()
	{
		this.queues[this.current].popFront;
		this.current = (this.current + 1) % this.queues.length;
	}

	int opApply(int delegate(Message) proceed)
	{
		for (;;)
		{
			auto pending = await(this.pending);
			if (pending == -1)
				return 0;

			if (auto result = proceed(this.next))
				return result;
		}
	}

	auto opSlice()
	{
		Message[] list;
		foreach (msg; this)
			list ~= msg;
		return list;
	}

}

/// Bidirection : start , put*2 , take
unittest
{
	static void summing(Output!int sums, Input!int feed)
	{
		sums.next = feed.next + feed.next;
	}

	Output!int feed;
	Input!int sums;
	go!summing(sums.pair, feed.pair);

	feed.next = 3;
	feed.next = 4;
	sums.next.assertEq(3 + 4);
}


/// Bidirection : put*2 , start , take
unittest
{
	static void summing( Output!int sums , Input!int feed )
	{
		sums.next = feed.next + feed.next;
	}

	Output!int feed;
	auto ifeed = feed.pair;
	feed.next = 3;
	feed.next = 4;
	feed.end;

	Input!int sums;
	go!summing( sums.pair , ifeed );

	sums.next.assertEq( 3 + 4 );
}

/// Round robin : start*2 , put*4 , take*2
unittest
{
	Output!int feed;
	Input!int sums;

	static void summing( Output!int sums , Input!int feed )
	{
		sums.next = feed.next + feed.next;
	}

	go!summing( sums.pair , feed.pair );
	go!summing( sums.pair , feed.pair );
	
	feed.next = 3; // 1
	feed.next = 4; // 2
	feed.next = 5; // 1
	feed.next = 6; // 2

	sums[].sort().assertEq([ 3 + 5 , 4 + 6 ]);
}

/// Event loop on multiple queues
unittest
{
	static void generating1( Output!int numbs )
	{
		numbs.next = 2;
		numbs.next = 3;
	}

	static void generating2( Output!long numbs )
	{
		numbs.next = 4;
		numbs.next = 5;
	}

	auto numbs1 = go!generating1;
	auto numbs2 = go!generating2;

	int[] results1;
	long[] results2;

	for(;;) {
		if( !numbs1.empty ) { results1 ~= numbs1.next; continue; }
		if( !numbs2.empty ) { results2 ~= numbs2.next; continue; }
		break;
	}

	results1.assertEq([ 2 , 3 ]);
	results2.assertEq([ 4 , 5 ]);
}

/// Blocking on buffer overflow
unittest
{
	static auto generating( ) {
		return 1.repeat.take( 200 );
	}

	auto numbs = go!generating;
	Thread.sleep( 10.msecs );

	numbs[].sum.assertEq( 200 );
}


/// https://tour.golang.org/concurrency/1
/// "go" template starts function in new asynchronous coroutine
/// Coroutines starts in thread pool and may be executed in parallel threads.
/// Only thread safe values can be passed to function.
unittest
{
	import core.time;
	import std.range;
	import jin.go;

	__gshared static string[] log;

	static void saying( string message )
	{
		foreach( _ ; 3.iota ) {
			Thread.sleep( 100.msecs );
			log ~= message;
		}
	}

	go!saying( "hello" );
	Thread.sleep( 50.msecs );
	saying( "world" );

	log.assertEq([ "hello" , "world" , "hello" , "world" , "hello" , "world" ]);
}

/// https://tour.golang.org/concurrency/3
/// Queue is one-consumer-one-provider wait-free typed queue with InputRange and OutputRange interfaces support.
/// Use "next" property to send and receive messages;
unittest
{
	import jin.go;

	Output!int output;
	auto input = output.pair;
	output.next = 1;
	output.next = 2;
	input.next.assertEq( 1 );
	input.next.assertEq( 2 );
}

/// https://tour.golang.org/concurrency/2
/// Inputs is round robin input Queue list with InputRange and Queue interfaces support.
/// Method "pair" creates new Queue for every coroutine
unittest
{
	import std.algorithm;
	import std.range;
	import jin.go;

	static auto summing( Output!int sums , const int[] numbers ) {
		sums.next = numbers.sum;
	}

	immutable int[] numbers = [ 7 , 2 , 8 , -9 , 4 , 0 ];

	Input!int sums;
	go!summing( sums.pair(1) , numbers[ 0 .. $/2 ] );
	go!summing( sums.pair(1) , numbers[ $/2 .. $ ] );
	auto res = (&sums).take(2).array;

	( res ~ res.sum ).sort.assertEq([ -5 , 12 , 17 ]);
}

/// https://tour.golang.org/concurrency/4
/// You can iterate over Queue by "foreach" like InputRange, and all standart algorithms support this.
/// Use "close" method to notify about no more data.
unittest
{
	import std.range;
	import jin.go;

	static auto fibonacci( Output!int numbers , size_t count )
	{
		auto range = recurrence!q{ a[n-1] + a[n-2] }( 0 , 1 ).take( count );
		foreach( x ; range ) numbers.next = x;
	}

	Input!int numbers;
	go!fibonacci( numbers.pair(10) , 10 );

	numbers[].assertEq([ 0 , 1 , 1 , 2 , 3 , 5 , 8 , 13 , 21 , 34 ]);
}

/// https://tour.golang.org/concurrency/4
/// Function can return InputRange and it will be automatically converted to input Queue.
unittest
{
	import std.range;
	import jin.go;

	static auto fibonacci( int limit )
	{
		return recurrence!q{ a[n-1] + a[n-2] }( 0 , 1 ).take( limit );
	}

	fibonacci( 10 ).array.assertEq([ 0 , 1 , 1 , 2 , 3 , 5 , 8 , 13 , 21 , 34 ]);
	go!fibonacci( 10 ).array.assertEq([ 0 , 1 , 1 , 2 , 3 , 5 , 8 , 13 , 21 , 34 ]);
}

/// https://tour.golang.org/concurrency/5
/// Use custom loop to watch multiple Queues as you want.
/// Provider can be slave by using "needed" property.
/// Use "yield" to allow other coroutines executed between cycles.
unittest
{
	import std.range;
	import jin.go;

	__gshared int[] log;

	static auto fibonacci( Output!int numbers )
	{
		auto range = recurrence!q{ a[n-1] + a[n-2] }( 0 , 1 );

		while( numbers.available >= 0 ) {
			numbers.next = range.next;
		}

	}

	static void printing( Output!bool controls , Input!int numbers )
	{
		foreach( i ; 10.iota ) log ~= numbers.next;
	}

	Output!int numbers;
	Input!bool controls;

	go!printing( controls.pair(1) , numbers.pair(1) );
	go!fibonacci( numbers );

	await( controls.pending );

	log.assertEq([ 0 , 1 , 1 , 2 , 3 , 5 , 8 , 13 , 21 , 34 ]);
}
/+
/// https://tour.golang.org/concurrency/6
/// You can ommit first argument of Queue type, and it will be autogenerated and returned.
unittest
{
	import core.time;
	import jin.go;

	static auto after( ref Output!bool signals , Duration dur )
	{
		Thread.sleep( dur );
		signals.next = true;
		return signals.available >= 0;
	}

	static auto tick( Output!bool signals , Duration dur )
	{
		while( after( signals , dur ) ) {}
	}

	auto ticks = go!tick( 101.msecs );
	auto booms = go!after( 501.msecs );

	string log;

	for(;;) {
		if( ticks.pending > 0 ) {
			log ~= "tick";
			ticks.popFront;
			continue;
		}
		if( booms.pending > 0 ) {
			log ~= "BOOM!";
			break;
		}
		log ~= ".";
		Thread.sleep( 51.msecs );
	}

	while( booms.clear )
	{
		while( !ticks.empty ) {
			log ~= "tick";
			ticks.popFront;
		}
	}

	log.assertEq( "..tick..tick..tick..tick..BOOM!" );
}

/// https://tour.golang.org/concurrency/9
unittest
{
	import core.atomic;
	import core.time;
	import std.range;
	import std.typecons;
	import jin.go;

	synchronized class SafeCounter
	{
		private int[string] store;

		void inc( string key )
		{
			++ store[key];
		}

		auto opIndex( string key )
		{
			return store[ key ];
		}
		void opIndexUnary( string op = "++" )( string key )
		{
			this.inc( key );
		}
	}

		scope static counter = new shared SafeCounter;

	static void working( int i )
	{
		++ counter["somekey"];
	}

	foreach( i ; 1000.iota ) {
		go!working( i );
	}

	Thread.sleep( 1.seconds );

	counter["somekey"].assertEq( 1000 );
}
+/