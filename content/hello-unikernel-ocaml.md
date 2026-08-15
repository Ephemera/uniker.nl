---
title: Your first unikernel in OCaml
description: OCaml is better than C
---

C is a good language for low-level programming, which is why Solo5 is
implemented in C, but we would like to switch to a much 'safer' and more
expressive language, namely OCaml. To this end, we are developing and
maintaining a modified version of the OCaml compiler, available here:
[ocaml-solo5][ocaml-solo5]. This compiler can be installed via:

```shell
$ opam install ocaml-solo5
```

Just like Solo5, it provides an OCaml _toolchain_ for building an unikernel in
OCaml. Here is an example of OCaml code:

```ocaml
let () = print_endline "Hello World!"
```

To do this, we need another C file, **startup.c**, which will define our
`solo5_app_main` function and run the OCaml code:

:::annotate
```c
#ifdef __ocaml_solo5__
#include "solo5.h"
#include <caml/callback.h>

static char *argv[] = { "unikernel", NULL };

void _nolibc_init(uintptr_t, size_t);

int solo5_app_main(const struct solo5_start_info *si) {
```

Since Solo5 offers very little, `ocaml-solo5` provides certain building blocks
(such as `malloc()`) required by OCaml. These functions are notably provided by
our aptly named `nolibc`. Furthermore, we must initialise this library in order
to specify the available "heap" to it.
```c
  _nolibc_init(si->heap_start, si->heap_size);
```

`caml_startup` is the function that will execute the OCaml code we have linked
to our unikernel.
```c
  caml_startup(argv);
  return (0);
}
#endif
```

:::

## Compilation

Next, we'll use `ocamlfind`, a utility that orchestrates the OCaml compiler
`ocamlopt` so that we can build our unikernel:

:::annotate
```shell
$ ocamlfind opt -toolchain solo5 -c startup.c -o startup.o
```

Note the `manifest.o` file that was built
[earlier][earlier], as well as the `-cclib "-z solo5-abi=hvt"` option. Without these options, the unikernel would be
malformed.
```shell
$ ocamlfind opt -toolchain solo5 startup.o manifest.o main.ml \
  -cclib "-z solo5-abi=hvt" -o main.hvt
```

:::



## Execution

Just like our previous unikernel, all you need to do is run our unikernel using `solo5-hvt`:
```shell
$ solo5-hvt main.hvt
            |      ___|
  __|  _ \  |  _ \ __ \
\__ \ (   | | (   |  ) |
____/\___/ _|\___/____/
Solo5: Bindings version v0.12.0
Solo5: Memory map: 512 MB addressable:
Solo5:   reserved @ (0x0 - 0xfffff)
Solo5:       text @ (0x100000 - 0x150fff)
Solo5:     rodata @ (0x151000 - 0x169fff)
Solo5:       data @ (0x16a000 - 0x375fff)
Solo5:       heap >= 0x376000 < stack < 0x20000000
Hello World!
Solo5: solo5_exit(0) called
```

There you go – you've created your very first unikernel in OCaml!

## Some notes

At this stage, it is important to describe two features of `ocaml-solo5`:
1) `ocaml-solo5` is essentially used to provide a consistent toolchain for
compiling C files alongside OCaml files. However, `ocaml-solo5` **does not**
compile OCaml files any differently. Better still, it is possible to use pure
OCaml libraries compiled using your default compiler (and installed via OPAM)
within your unikernel:

```ocaml
let () = Fmt.pr "Hello World!"
```

```shell
$ ocamlfind opt -toolchain solo5 -linkpkg -package fmt \
  startup.o manifest.o main.ml \
  -cclib "-z solo5-abi=hvt" -o main.hvt 
```

2) The OCaml distribution contains libraries that allow interaction with the
system, such as the `Unix` module. However, in the case of `ocaml-solo5`, it is
**impossible** and **undesirable** for us to provide such a module. In other
words, you must treat the Unix module as if it did not exist in the context of
unikernels.

[ocaml-solo5]: https://github.com/mirage/ocaml-solo5
[earlier]: /hello-unikernel/#a-solo5-manifest
