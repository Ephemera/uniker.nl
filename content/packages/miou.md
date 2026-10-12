---
name: Miou
version: 0.8.0
kind: library
description: A simple scheduler for OCaml 5
repo: https://github.com/robur-coop/miou
homepage: https://github.com/robur-coop/miou
tags: [scheduler, effects]
authors:
  - name: Romain Calascibetta
    email: romain.calascibetta@gmail.com
    url: https://din.osau.re/
---

Miou is what is known as a scheduler for OCaml that utilises the effects
introduced in OCaml 5 to provide a suspension and continuation mechanism that
is transparent to the user.

Miou allows you to manage so-called asynchronous tasks (i.e. tasks that run
concurrently on the same core) as well as parallel tasks (i.e. tasks that run
on a different core from the one in which they were created). Miou therefore
provides what is known as a _domain pool_ ready to manage parallel tasks.

If you're interested in the topic of schedulers and effects, [our
tutorial][miou-tutorial] on unikernels introduces you to these concepts by
helping you to implement a simple scheduler using OCaml 5.

An overview with practical examples of Miou is also available
[here][miou-overview]. These examples introduce the `Miou_unix` module, which
is **not** compatible with unikernels (and is used to create simple executables
with Miou).

## API

:::document

```ocaml
type 'a t
```

The type of our promises. A promise is a value associated with a task that is
currently running. It is by means of this promise that the user can wait for a
task to complete and obtain its result (of type `'a`).

---

### Spawn tasks

Miou offers two ways to _spawn_ tasks: you can launch them in the current
domain, or specify that the task should be launched in a domain that is
explicitly different from the current one.

```ocaml
val async :
     ?give:Ownership.t list
  -> ?orphans:'a orphans
  -> (unit -> 'a)
  -> 'a t
```

`async fn` returns a _promise_ `t` representing the state of the task `fn` given as an
argument. The task will be executed **concurrently** with the other tasks in the
current domain.

It raises:
- `Invalid_argument` when we would like to attach an orphans which is **not** own by
  the parent promise. For instance, this code doesn't work because we're trying to
  attache 2 promises that don't have the same direct parent:

'''ocaml
# Miou.run @@ fun () ->
  let orphans = Miou.orphans () in
  let prm = Miou.async ~orphans @@ fun () ->
    let prm = Miou.async ~orphans (Fun.const ()) in
    Miou.await_exn prm in
  Miou.await_exn prm ;;
Exception: Invalid_argument "The given orphans is owned by another promise"
'''

```ocaml
val call :
     ?pin:Domain.Uid.t
  -> ?give:Ownership.t list
  -> ?orphans:'a orphans
  -> (unit -> 'a)
  -> 'a t
```

`call fn` returns a promise `t` representing the state of the parallel task given as an
argument. The task will be run in parallel: the domain used to run the task is different
from the domain with the promise. This assertion is always true:

'''ocaml
let () = Miou.run @@ fun () ->
  let p = Miou.call @@ fun () ->
    let u = Miou.Domain.self () in
    let q = Miou.call @@ fun () -> Miou.Domain.self () in
    (u, Miou.await_exn q) in
  let u, v = Miou.await_exn p in
  assert (u <> v)
'''

Sequential calls to `call` do not guarantee that different domains are always chosen.
This code **may** be true.

'''ocaml
let () = Miou.run @@ fun () ->
  let p = Miou.call @@ fun () -> Miou.Domain.self () in
  let q = Miou.call @@ fun () -> Miou.Domain.self () in
  let u = Miou.await_exn p in
  let v = Miou.await_exn q in
  assert (u = v)
'''

To ensure that tasks are properly allocated to all domains, you need to use `parallel`.

**NOTE**: `call` will never run a task on _dom0_ (the main domain). Only the other domains
can manage parallel tasks.

It raises:
- `No_domain_available` if no domain is to execute the task in parallel or if the function
  is executed by the only domain available in parallel (it is impossible to assign task to
  `dom0` from the other domains)
- `Invalid_argument` like `async`, if the promise want to be associated with an `orphan`,
  the orphan should be owned by the direct parent.

```ocaml
```

```ocaml
val parallel : ('a -> 'b) -> 'a list -> ('b, exn) result list
```

`parallel fn lst` is the _fork-join_ model: it is a way of setting up and
executing parallel tasks, such that, such that execution branches off in
parallel at designated points in the program, to "join" (merge) at a subsequent
point and resume sequential execution.

Let's take the example of a sequential merge-sorte:

'''ocaml
let sort ~compare (arr, lo, hi) =
  if hi - lo >= 2 then begin
    let mi = (lo + hi) / 2 in
    sort ~compare (arr, lo, mi);
    sort ~compare (arr, mi, hi);
    merge ~compare arr lo mi hi
  end
'''

---

### Ownership

> La propriété, c'est du vol!

In system programming, we often work with resources such as "file descriptors"
representing files or _sockets_. These resources can be allocated but must also
be released. Miou provides a system to help developers ensure that the
resources required by their programs are released correctly.

This module is all the more necessary given that Miou introduces the concept of
task cancellation: in other words, a task may cease to run depending on the
decision made by its parent. It may be the case that a resource has been
allocated to a task that we wish to cancel, so we need to find a way to release
that resource as well when the task is cancelled.

```ocaml
module Ownership : sig
```

```ocaml
  type t
```

A resource type represents an association between a value (any value) and its
_finaliser_, that is, a function that releases that resource.

```ocaml
  val create : finally:('a -> unit) -> 'a -> t
```

`create ~finally v` associates a value `v` and its _finaliser_ `finally` to
return a _resource_.

```ocaml
  val check : t -> unit
```

`check resource` verifies that the given `resource` is _owned_ by the current
task. If a task tries to use a resource that does not belong to it, `check`
will raise an _uncatchable_ exception `Not_owner`. To make a resource belong to
a task, you must use `Miou.Ownership.own` (so that the current task takes
ownership of it).

```ocaml
  val own : t -> unit
```

`own resource` associates the given `resource` to the current task. This way,
if the current task fails abnormally, the `finally` function will be called.

'''ocaml
# let show () = print_endline "Resource released!" ;;
# Miou.run @@ fun () ->
  let p = Miou.async @@ fun () ->
    let t = Miou.Ownership.create ~finally:show () in
    Miou.Ownership.own t;
    failwith "Boum!" in
  Miou.await_exn p ;;
Resource released!
Exception: Failure "Boum!".
'''

**NOTE**: Finaliser **can not** perform OCaml's effects. This is because it is
not "ordered" like usual task. Using Miou functions (such as `await` or
`cancel`) in the finaliser will raise an exception `Effect.Unhandled`.

It is also important to note that if a task finishes abnormally, as well as
freeing up the resources of that task, teh resources owned by the children will
also be freed up.

```ocaml
  val disown : t -> unit
```

`disown resource` informs Miou that you have properly released the resource. If
the current task ends well and the user has not `disown` the resource, Miou
raises the uncatchable exception: `Resource_leaked`.

'''ocaml
# let show () = print_endline "Resource released!" ;;
# Miou.run @@ fun () ->
  let p = Miou.async @@ fun () ->
    let t = Miou.Ownership.create ~finally:show () in
    Miou.Ownership.own t in
  Miou.await_exn p ;;
Resource released!
Exception: Miou.Resource_leak.
'''

Note that even in this abnormal situation, Miou calls the finaliser.

However, `finally` **is not** called by `disown`, For example, if we had
associated `Unix.close` as a `finally` with a file descriptor as a resource,
`disown` **does not** close the file descriptor and it is up to the user to
explicitly close the file descriptor.

If you want to `disown` **and** call `finally`, you should use `release`.

```ocaml
  val release : t -> unit
```

`release resource` properly releases the resource (and call `finally`) and
informs Miou that the resource is properly released. If the current task fails
(via cancellation or exception) after `release`, the resource finaliser will
not be called.

```ocaml
  val transfer : t -> unit
```

`transfer resource` transfers the ownership of a resource to the parent task. It
is useful when a sub-task operates to the resource owned by its parent and would like to
retransfer it at the end:

'''ocaml
exception Timeout

let with_timeout ~give secs fn =
  let prm0 = Miou.async @@ fun () -> Miou_unix.sleep secs; raise Timeout in
  let prm1 = Miou.async ~give fn in
  Miou.await_first [ prm0; prm1 ]

let connect socket sockaddr =
  let finally = Unix.close in
  let t = Miou.Ownership.create ~finally socket in
  Miou.Ownership.own t;
  with_timeout ~give:[t] @@ fun () ->
  Unix.connect socket sockaddr;
  Miou.Ownership.transfer t
'''

```ocaml
end
```

---

```ocaml
type 'a orphans
```

### Orphanage for tasks

In accordance with our first rule, which is to be able to wait for (or cancel)
all our tasks, there is a `orphans` value.

This value can hold _promises_ (using the `~orphans` option for the
`Miou.async` and `Miou.call` functions) and allows us to return the promise
that is in a stopped state (i.e. it has completed successfully, an exception
has been thrown from that task, or it has been cancelled). Since the tasks
returned by `orphans` are in the ‘stopped’ state, the subsequent use of
`Miou.await{,_exn}` is **non-blocking**.

Here is an example of an echo server using `orphans`. The aim is to collect
tasks that have completed during a server _tick_ (`Miou_unix.accept`) in order
to consume their results. If we did not consume the tasks, they would never be
released (and this would result in a memory leak).

'''ocaml
let rec clean_up orphans = match Miou.care orphans with
  | None -> () (* [orphans] has no task *)
  | Some None -> () (* [orphans] has no terminated task *)
  | Some (Some prm) ->
    let _ = Miou.await prm in
    clean_up orphans

let run main handler =
  let rec go orphans =
    clean_up orphans; (* clean-up *)
    let flow, _ = Miou_unix.accept main in
    (* record our new promise into [orphans] *)
    let _ = Miou.async ~orphans @@ fun () ->
      handler flow in
    go orphans in
  go (Miou.orphans ())
'''

The `orphans` can only contain tasks that are related to the **same** parent.

```ocaml
val orphans : unit -> 'a orphans
```

It make a new _orphan collectors_ which can be used by `call` and `async`.

:::

[miou-tutorial]: /miou-scheduler#a-hand-written-scheduler-in-ocaml
[miou-overview]: /miou-scheduler#miou-through-examples
