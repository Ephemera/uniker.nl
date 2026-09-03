---
title: Miou, a simple scheduler for unikernels
description: The first piece of our unikernel
---

[Miou][miou] is a simple scheduler written in pure OCaml that allows tasks to
be launched cooperatively: the aim is to have several tasks running _at the
same time_ so that, for example, our unikernel can handle several clients _at
the same time_ (in reality, these tasks do not run simultaneously as we only
have a single vCPU available for our unikernel, but the scheduler seizes
opportunities to execute some of our tasks whilst others are blocked).

In this chapter, we will first attempt to create our own scheduler from scratch
in order to understand what a scheduler does. Next, we will introduce you to
Miou with a few fairly simple examples.

## A hand-written scheduler in OCaml

The idea behind a scheduler is to be able to have a task that runs in the
background without blocking the execution of other tasks, such as our main
task. In other words, we would like to be able to write the following:

```ocaml
let fn () = print_endline "World"

let () =
  do_it_in_background fn;
  print_endline "Hello"
```

We would like "Hello" to be displayed first, followed by the execution of our
`fn` function, and then "World" to be displayed. Our scheduler would be
responsible for executing `fn`. It is generally accepted that there should be
some sort of _witness_ (or _promise_) for the task that will execute `fn`. In
this way, we will know whether `fn` has actually been executed and in what state
the task ended.

```ocaml
let fn () = print_endline "World"

let () =
  let promise = do_it_in_background fn in
  print_endline "Hello";
  match await promise with
  | Ok () -> ()
  | Error exn -> raise exn
```

We now have what any OCaml scheduler should, in principle, provide. We will
therefore set about implementing a scheduler that should provide the functions
`do_it_in_background` and `await`. To do this, we will introduce you to a new
concept in OCaml 5: [effects][effects].

### Effects

One way of looking at effects in OCaml is probably to compare them with
exceptions. The advantage of an exception is that it allows you to _interrupt_
the execution of a function in order to _jump_ to another part of the code:

```ocaml
let () =
  try print_endline "Hello" ;
      raise Break;
      print_endline "Unikernel"
  with Break ->
      print_endline "World"
```

Effects share the same feature of being able to interrupt execution and jump to
another part of the code. However, they can also _return_ to the point where
the interruption occurred!

```ocaml
open Effect.Deep

type _ Effect.t += Break : unit Effect.t

let () =
  match print_endline "Hello";
        Effect.perform Break;
        print_endline "Unikernel"
  with
  | effect Break, k ->
    print_endline "World";
    continue k ()
  | () -> ()
```

This is the basic principle behind effects. As far as our scheduler is
concerned, this will allow us to switch between application code and our
scheduler's implementation (just as we can switch from user space to kernel
space for a normal executable) and return to the breakpoint. We will therefore
be able to manage and execute tasks _behind_ our application.

### A simple task

A task can be described as follows:
- it is a function representing a piece of code that we should execute
- it is a piece of code that has been paused at a certain point and which we can
  _resume_
- it is a result (what this piece of code produces) or an error

Its equivalent in OCaml is:

```ocaml
open Effect.Shallow

type 'a state =
  | Initial of (unit -> 'a)
  | Suspended : ('c, 'a) continuation * 'c Effect.t -> 'a state
  | Resolved of ('a, exn) result
```

Next, we’ll define a _handler_ that will allow us to specify what to do when an
effect occurs, an exception is thrown, or the function terminates:

```ocaml
let handler =
  let open Effect.Shallow in
  let retc v = Resolved (Ok v)
  and exnc exn = Resolved (Error exn)
  and effc : type c. c Effect.t -> ((c, 'a) continuation -> 'b) option
    = fun eff -> Some (fun k -> Suspended (k, eff)) in
  { retc; exnc; effc }
```

Finally, a task can simply be defined as the state of our piece of code:

```ocaml
type task = Task : 'a state -> task
```

### A promise

Schedulers often provide a _promise_ value. This acts as a witness for the
task, showing whether or not it has been completed. It is called a promise
because it represents a value that "should" appear in the future (once the task
is complete). It is therefore a value that will change, which is why we define
our promise as such for our scheduler:

```ocaml
type 'a promise = ('a, exn) result option ref
```

Next, we'll finally define our first two effects: one for running a task in the
background, and one for waiting for a task to finish:

```ocaml
type _ Effect.t += Spawn : (unit -> 'a) -> 'a promise Effect.t
type _ Effect.t += Await : 'a promise -> ('a, exn) result Effect.t
```

### Our basic scheduler

A scheduler is basically a program that maintains a list of tasks to be carried
out. It simply tries to work through this list until there are no more tasks
left. In this case, our `Spawn` effect adds a task to this list and our `Await`
effect will _watch_ our promise and either return the result or ask our
scheduler to execute the other tasks (which may lead to the result being
obtained).

```ocaml
let perform
  : type c. task list -> c Effect.t -> [ `Continue of c | `Yield ] * task list
  = fun todo -> function
  | Spawn fn ->
    let promise = ref None in
    let task = Initial (fun () -> promise := Some (Ok (fn ()))) in
    `Continue promise, todo @ [ Task task ]
  | Await value -> begin match !value with
    | Some value -> `Continue value, todo
    | None -> `Yield, todo end
  | _ -> invalid_arg "Invalid effect"
```

The next step is to _move a task forward_ so that part of it is executed and a
new version of the task is created.

```ocaml
let step todo = function
  | Initial fn ->
    let k = Effect.Shallow.fiber fn in
    Effect.Shallow.(continue_with k () handler), todo
  | Resolved _ as value -> value, todo
  | Suspended (k, eff) ->
    match perform todo eff with
    | `Continue v, todo -> Effect.Shallow.(continue_with k v handler), todo
    | `Yield, todo -> Suspended (k, eff), todo
```

Finally, the core of our scheduler consists of a loop that continues until
there are no more tasks left. The aim is to advance our tasks (using the `step`
function) until they have all been completed.

:::annotate

```ocaml
let run fn =
```


This is our main loop, which will stop when our list is empty (and, therefore,
when there are no more tasks to do).

```ocaml
  let rec go = function
    | [] -> ()
    | Task task :: todo ->
      let state, todo = step todo task in
      match state with
```

Once a task has been ‘completed’, you can simply move on to the others
(`todo`).

```ocaml
      | Resolved _ -> go todo
```

Otherwise, we add our task back to our list (as it isn't finished).

```ocaml
      | (Initial _ | Suspended _) as task ->
        go (todo @ [ Task task ]) in
```

This value will be the return value of our `fn` function. This is the promise
returned by our initial task `fn`. We then need to run our loop with this task,
and `result` should contain its result.

```ocaml
  let result = ref None in
  let task = Initial (fun () -> result := Some (fn ())) in
  go [ Task task ]; Option.get !result
```

:::

### A simple program with our scheduler

Do you remember our very first programme? We can now implement it as follows:

```ocaml
let fn () = print_endline "World"

let () = run @@ fun () ->
  let promise = Effect.perform (Spawn fn) in
  print_endline "Hello";
  match Effect.perform (Await promise) with
  | Ok () -> ()
  | Error exn -> raise exn
```

If we run this code, we do indeed see "Hello" and "World" displayed one after
the other (even though we _spawned_ `fn` before our `print_endline`). That's
the principle behind schedulers! Now that you understand the principle, we can
introduce Miou with a few examples.

## Miou through examples

Miou is therefore simply a scheduler. Its sole purpose is **only** to manage
tasks. We will look at I/O management in relation to unikernels using `mkernel`
later on. We will therefore use fairly general examples to understand how Miou
works. In this case, this scheduler has certain rules that developers must
strictly adhere to, and we will describe them here.

### Never forget your tasks

Miou has one fundamental rule: **never** forget your tasks. A task is
considered to be a resource and, like all resources, it has a creation phase
(using `Miou.async` or `Miou.call` - which corresponds to our `Spawn`) and a
release phase (using `Miou.await`). So, as soon as you create a task, there
should be a `Miou.await` on the promise not far away.

If this is not the case, Miou throws a `Still_has_children` exception:
```ocaml
# require "miou" ;;
# let () = Miou.run @@ fun () ->
    let _promise = Miou.async (Fun.const ()) in
    () ;;
Exception: Miou.Still_has_children
```

You must therefore either ensure that a task has completed successfully and
retrieve its result using `Miou.await`, or cancel that task using
`Miou.cancel`.

```ocaml
let () = Miou.run @@ fun () ->
  let promise0 = Miou.async (Fun.const ()) in
  let promise1 = Miou.async (Fun.const ()) in
  Miou.await_exn promise0;
  Miou.cancel promise1
```

### Structured concurrency

Miou offers a form of task management known as [structural][wiki]: that is to
say, there is a link between tasks, and in particular between tasks and their
_children_. A child is a _sub-task_ created from a task known as its parent.

:::annotate

```ocaml
let () = Miou.run @@ fun () ->
  let parent = Miou.async @@ fun () ->
```

It is said that `child` is a child of the `parent` task.

```ocaml
    let child = Miou.async (Fun.const ()) in
    Miou.await_exn child in
  Miou.await_exn parent
```

:::

Miou considers that a subtask can only be awaited (or cancelled) by its parent.
The parent is said to ‘own’ its subtasks. If a task awaits another when there
is no such parent-child relationship between the two, Miou raises the
`Not_a_child` exception:

```ocaml
# let () = Miou.run @@ fun () ->
    let q = Queue.create () in
    let promise0 = Miou.async @@ fun () ->
      let sub = Miou.async (Fun.const ()) in
      Queue.push sub q;
      Miou.await_exn sub in
    let promise1 = Miou.async @@ fun () ->
      while Queue.is_empty q do Miou.yield () done;
      let sub = Queue.pop q in
      Miou.await_exn sub in
    Miou.await_exn promise0;
    Miou.await_exn promise1
  ;;
Exception: Miou.Not_a_child
```

This example is interesting because it illustrates why we might want a subtask
to be shared between two tasks: to transfer information (in this case, we are
attempting to do so via a shared queue).

In reality, Miou forces you to think about this issue using methods other than
tasks: by means of a queue (possibly an atomic one), an array shared with a
mutex, or a _write-once_ variable.

This rule that one can only wait for one's own children also applies to
cancellation; one can only cancel one's direct descendants.

### Concurrency

One of the benefits of the scheduler is that it allows you to attempt to run
several tasks at the same time and set a time limit on the execution of a task,
rather than waiting indefinitely.

One of the best-known examples is attempting to connect to a service and
cancelling the connection after a certain amount of time:

:::annotate

```ocaml
exception Timeout

let () = Miou_unix.run @@ fun () ->
  let socket = Miou_unix.tcpv4 () in
  (* localhost:80 *)
  let sockaddr = Unix.(ADDR_INET (inet_addr_loopback, 80)) in
```

We launch an initial task that will attempt a TCP connection to `localhost:80`.

```ocaml
  let promise0 = Miou.async @@ fun () ->
    Miou_unix.connect socket sockaddr in
```

And a second one which, at the same time, will wait for 10 seconds and throw an
exception.

```ocaml
  let promise1 = Miou.async @@ fun () ->
    Miou_unix.sleep 10.;
    raise Timeout in
```

We end up waiting for the first of the two tasks to complete. This means we
don't have to wait more than 10 seconds to try to connect to the service.

```ocaml
  match Miou.await_first [ promise0; promise1 ] with
  | Ok () -> Miou_unix.close socket
  | Error Timeout -> prerr_endline "Timeout"
  | Error exn -> raise exn
```

:::

`Miou.await_first` will wait for the first of the two tasks to complete, but it
will also cancel the other task. It is said to cancel (`Miou.cancel`) all other
tasks that have not yet completed. In this way, we comply with our first rule.

### Background tasks

Miou offers _a design pattern_ that is fairly straightforward to understand
when it comes to setting up a service that needs to handle multiple clients.
For this type of application, one usually ends up _accepting_ clients and
creating a "standalone" task for each client so that they can be managed
_simultaneously_ whilst new clients are being accepted.

These "standalone" tasks are known as background tasks; in other words, they
continue to run (to manage clients) whilst our main task is to accept new
clients.

To manage these tasks, using the same terminology as for _children_ and
_parents_, we refer to an _orphanage_ to keep these tasks in the background.
The idea is to keep track of these tasks and be able to check whether any of
them have been completed (because, according to our first rule, we must not
forget our tasks).

:::annotate

The aim of this function is to collect the children from our orphanage who have
terminated.

```ocaml
let rec clean_up orphans = match Miou.care orphans with
  | Some None | None -> ()
  | Some (Some promise) ->
```

This relates to our first rule: all our tasks must be either `await` or
`cancel`. `Miou.care` ensures that the given promise has been fulfilled.

```ocaml
    begin match Miou.await promise with
    | Ok () -> clean_up orphans
    | Error _exn -> () end

let () = Miou_unix.run @@ fun () ->
  let main = Miou_unix.tcpv4 () in
  (* localhost:8080 *)
  Miou_unix.bind_and_listen main
    Unix.(ADDR_INET (inet_addr_loopback, 8080));
```

This is our main loop, which will _accept_ our new customers.

```ocaml
  let rec go orphans =
```

Our `clean_up` function does not block, but it ensures that our completed
clients are properly released at this _sweet spot_.

```ocaml
    clean_up orphans;
    let socket, _ = Miou_unix.accept main in
```

And for every new customer, we create a new task to manage them. This task can
be ignored as it is stored in the given `orphans`.

```ocaml
    let _ = Miou.async ~orphans (fun () -> handle_client socket) in
    go orphans in
  go (Miou.orphans ())
```
:::

`orphans` also adheres to the rules on parentage in the sense that this value
should not be manipulated by any task other than the one that _spawns_ the
subtasks. Generally speaking, just as `Miou.await` is never far from
`Miou.async`, `orphans` is never far away and rarely extends beyond the lexical
scope of where it was created.

### Daemon

Another example, when developing an application, is having a background task to
which we would like to send instructions on what actions to perform. This
concept is generally referred to as a _daemon_.

This daemon exists and should terminate when our unikernel shuts down. We
should then provide the ability to pass actions to this daemon.

:::annotate

Here is a basic action that involves displaying content.

```ocaml
type action =
  | Print of string
```

A daemon often manipulates a state. In our example, this consists of a series
of actions that the daemon must perform. The `mutex` allows the state to be
manipulated by several tasks _at the same time_, and the `condition` allows us
to _wake up_ our daemon if it is waiting for actions.

```ocaml
type state =
  { queue : action Queue.t
  ; mutex : Miou.Mutex.t
  ; condition : Miou.Condition.t }

let rec go t =
  let actions = Miou.Mutex.protect t.mutex @@ fun () ->
    while Queue.is_empty t.queue do
```

Here, we wait for our shared queue to have some actions to process.

```ocaml
      Miou.Condition.wait t.condition t.mutex
    done;
    let actions = Queue.to_seq t.queue in
    let actions = List.of_seq actions in
    Queue.clear t.queue;
    actions in
  let fn = function
    | Print str -> print_endline str in
```

Then, we process them.

```ocaml
  List.iter fn actions;
  go t

let daemon () =
  let state =
    { queue= Queue.create ()
    ; mutex= Miou.Mutex.create ()
    ; condition= Miou.Condition.create () } in
```

We'll create our daemon here, which consists of a task and its state.

```ocaml
  state, Miou.async (fun () -> go state)

```

Finally, we provide a way to pass actions to our daemon. This involves adding
the action to our queue and waking up our daemon if it is in a waiting state.

```ocaml
let put elt t = Miou.Mutex.protect t.mutex @@ fun () ->
  Queue.push elt t.queue;
  Miou.Condition.signal t.condition

let () = Miou.run @@ fun () ->
  let state, daemon = daemon () in
```

Finally, we make sure to _kill_ our daemon at the end of our programme (in line
with our first rule).

```ocaml
  Fun.protect ~finally:(fun () -> Miou.cancel daemon) @@ fun () ->
  put (Print "Hello") state;
  put (Print "World") state
```

:::

This short example demonstrates a mechanism for transferring information (our
actions) to another task. As far as our unikernel is concerned, we'll have
quite a few _daemons_, just as you have plenty of [_daemons_][daemon] currently
running on your system. This is simply an illustration in OCaml.

### Ownership

Miou offers one final mechanism: ownership. This is a concept found in the Rust
programming language. It involves assigning a resource to a specific task. If
the task terminates abnormally or is cancelled, Miou will ensure that the
resource in question is _released_.

Here is a very practical example:

:::annotate

```ocaml
let () = Miou_unix.run @@ fun () ->
  let finally () = print_endline "Released!" in
  let promise0 = Miou.async @@ fun () ->
    let resource = Miou.Ownership.create ~finally () in
    Miou.Ownership.own resource;
```

Here, we ensure that `promise0` fails abnormally.

```ocaml
    raise Stdlib.Exit in
  let promise1 = Miou.async @@ fun () ->
    let resource = Miou.Ownership.create ~finally () in
    Miou.Ownership.own resource;
    Miou_unix.sleep 10. in
```

Even if `promise0` fails, the `finally` function will still run in order to
release the resource.

```ocaml
  ignore (Miou.await promise0);
```

And on this line, we cancel `promise1`. Just like `promise0`, even if the task
is cancelled, the `finally` function will be executed to release the resource.

```ocaml
  Miou.cancel promise1
```

:::

Here is an example of a task that handles a client and repeats what the latter
writes.

```ocaml
let handler socket =
  let tmp = Bytes.create 0x7ff in
  let finally = Miou_unix.close in
  let resource = Miou.Ownership.create ~finally socket in
  Miou.Ownership.own resource;
  let rec go () =
    let len = Miou_unix.read socket tmp ~off:0 ~len:0x7ff in
    if len > 0 then begin
      let str = Bytes.sub_string tmp 0 len in
      Miou_unix.write socket str;
      go ()
    end in
  go ();
  Miou.Ownership.release resource
```

#### Check and transfer

It can also sometimes be useful to transfer ownership of a task to another. For
example, we might first want to create a socket, acquire ownership of it,
attempt a connection using the same model described [here][concurrency] (and thus transfer
ownership to the task attempting the connection), and finally transfer our
socket back to the original task.

:::annotate

```ocaml
exception Timeout

let connect sockaddr =
  let socket = Miou_unix.tcpv4 () in
  let resource = Miou.Ownership.create ~finally:Miou_unix.close socket in
  Miou.Ownership.own resource;
```

The `give` argument is used to transfer a resource to a sub-task. After that,
our main task will no longer be responsible for `socket`; only `promise0` will
be responsible for it.

```ocaml
  let promise0 = Miou.async ~give:[ resource ] @@ fun () ->
    Miou_unix.connect socket sockaddr;
```

`Miou.Ownership.transfer` is the mechanism for transferring ownership to the
parent task - in this case, our main task.

```ocaml
    Miou.Ownership.transfer resource in
  let promise1 = Miou.async @@ fun () ->
    Miou_unix.sleep 10.; raise Timeout in
  match Miou.await_first [ promise0; promise1 ] with
  | Ok () -> socket
  | Error Timeout -> failwith "Timeout"
  | Error exn -> failwith "Unexpected exception"
```

:::

The advantage of this approach is that it ensures that, in the event of a
failure (if `Miou_unix.connect` fails) or cancellation (if `promise0` is
cancelled due to a timeout), a `Unix.close` is indeed called to release the
resource correctly.

## Conclusion

You know all about Miou now! In fact, Miou offers very few features and focuses
solely on scheduling. We’ve introduced you here and there to a few features of
`Miou_unix` (the version of Miou with the `Unix` module), but you’ve got the
basics down:
- creating and managing tasks
- orphanage for managing background tasks
- mutexes and conditions
- the principle of ownership

Next, there are plenty of interactions similar to `Miou_unix`, which we'll
explore bit by bit. This allows us to introduce you to a new layer: `mkernel`.
It’s an extension of Miou, but specifically for Solo5.

There is a whole ecosystem surrounding Miou and `Miou_unix` if you wish to
develop OCaml applications that are not unikernels. `mtbox` is a suite of tools
for debugging applications with Miou. In particular, we can recommend `vif`,
our OCaml web framework, or `blaze`, our Swiss Army knife for email.

Thanks to its simplicity, the mental model a developer needs to adopt when
thinking about scheduling is fairly straightforward and ultimately requires
knowledge of only around twenty functions. And that is precisely Miou’s aim: to
provide an extremely simple scheduler.

[vocal]: https://inria.hal.science/hal-01561094
[miou]: https://github.com/robur-coop/miou
[effects]: https://ocaml.org/manual/5.5/effects.html
[wiki]: https://en.wikipedia.org/wiki/Structured_concurrency
[daemon]: https://en.wikipedia.org/wiki/Daemon_(computing)
[concurrency]: /miou-scheduler/#concurrency
