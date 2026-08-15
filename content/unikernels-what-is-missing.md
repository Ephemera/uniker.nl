---
title: Unikernels, what is missing?
description: What we can do now with Solo5 & OCaml?
---

The unikernel approach is fundamentally radical in that the developer
ultimately has very little interaction with the outside world (compared to
POSIX). These interactions are:
- reading and writing an Ethernet frame
- reading and writing a page on a ‘block device’
- shutting down the unikernel

So there are only five possible interactions (hence the name Solo5) with
elements external to the unikernel. This is where the ‘kernel’ part begins, as
we need to be able to have:
- a scheduler
- a TCP/IP stack
- a file system

These are generally software components found on the kernel side (rather than
on the side of the application, which interacts with them via the POSIX API).
Here, in line with the concept of the unikernel, we will need to implement
and/or utilise implementations that will then enable us to develop our
applications on top of them.
