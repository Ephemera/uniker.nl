---
name: immuable
kind: unikernel
description: A static website
repo: https://github.com/dinosaure/immuable
homepage: https://robur.coop
tags: [web, https, website]
authors:
  - name: Romain Calascibetta
    email: romain.calascibetta@gmail.com
    url: https://din.osau.re/
---

Immuable is one of the first unikernels we developed using our new workflow.
The idea behind `immuable` is to offer the ability to serve content via the
HTTP protocol at very little cost. It is therefore an easy-to-understand
unikernel.

The unikernel is being developed in this [GitHub repository][github]. Users who
are already familiar with [OPAM][opam] can install it using this command:

```shell
$ opam pin add https://github.com/dinosaure/immuable.git
```

The project includes not only the unikernel that you can deploy, but also an
executable that allows you to generate the archive required by the unikernel
from a folder containing your static website.

## Immuable ☓ [YOCaml][yocaml]

To have a bit more fun, we're going to use the YOCaml project: it's a static
HTML content generator. In other words, for those of you who dream of
developing your own static blog system, YOCaml is a good solution. The aim here
will therefore be not only to generate our website in OCaml, but also to deploy
it in OCaml!

### A little website

To put it quite simply, our aim will be to start with a CommonMark document and
then generate HTML pages. YOCaml allows you to read files, transform them, and
then generate HTML files into a specific directory (like `_www`).

:::annotate

```ocaml
open Yocaml

let www = Path.rel [ "_www" ]
let pages = Path.rel [ "pages" ]
let templates = Path.rel [ "templates" ]

let track_binary = 
  Sys.executable_name
  |> Yocaml.Path.from_string
  |> Pipeline.track_file

let with_ext exts file =
  List.exists (fun ext -> Path.has_extension ext file) exts

```

This is where we carry out our main transformation, in which we take a `source`
and generate HTML, applying a _template_ file ([Jingoo][jingoo]).

```ocaml
let create_page source =
  let page_path =
    source
    |> Path.move ~into:www
    |> Path.change_extension "html"
  in
  let open Task in
  let read =
    let open Task in
    let+ () = track_binary
```

We are preparing our template, which is a transformation function based on
information relating to an `Archetype.Page`.

```ocaml
    and+ apply = Yocaml_jingoo.read_templates
      Path.[ templates / "page.html" ]
    and+ metadata, content = Yocaml_yaml.Pipeline.read_file_with_metadata
      (module Archetype.Page) source in
    (apply (module Archetype.Page) ~metadata, content)
  in
  read
```

Here, we convert the CommonMark file to HTML.

```ocaml
  >>> Yocaml_cmarkit.content_to_html ()
```

We apply our template (the content will be available via `yocaml_body`).

```ocaml
  >>> rmap (fun (fn, content) -> fn content) id
```

And we save this to an HTML file.

```ocaml
  |> Action.Static.write_file page_path

```

Finally, we apply this transformation to all the `*.md` files in our `pages`
folder.

```ocaml
let create_pages =
  let where = with_ext [ "md" ] in
  Batch.iter_files ~where pages create_page

let gen () =
  let open Eff in
  let cache = Path.(www / ".cache") in
  Action.restore_cache cache
  >>= create_pages
  >>= Action.store_cache cache

let () = Yocaml_unix.run ~level:`Debug gen
```

:::

You can supplement this small programme with a `dune` file to compile it, as
well as a `templates/page.html` file and a `pages/index.md` file:

`dune`:
```dune
(executable
 (name gen)
 (libraries yocaml yocaml_unix yocaml_yaml yocaml_cmarkit yocaml_jingoo))
``` 

`pages/index.md`:
```markdown
---
page_title: My super website
description: My homepage
tags: [index]
---

# Hello World!

This is my super website as an unikernel!
```

`templates/page.html`:
```html
<html>
<head>
<title>{{ page_title }}</title>
</head>
<body>
{{safe (yocaml_body) }} 
</body>
</html>
```

### Generate & pack!

At this stage, our little executable `gen.exe` can now generate our website in
the `_www` folder. If you’d like more details about YOCaml (how to generate
pages, include static content, etc.), you can refer to [this excellent
tutorial][yocaml-tutorial].  We'll now simply use `immuable` (which we've just
installed via OPAM) to produce the archive required for our unikernel and
launch our unikernel:

:::annotate

We generate our website using YOCaml.

```shell
$ dune exec ./gen.exe
```

We generate the archive from what YOCaml has generated.

```shell
$ immuable make -o pack.pack _www
```

We'll set up everything we need for our `immuable` unikernel (if you're unsure,
we recommend reading [our tutorial][mnet]).

```shell
$ sudo ip tuntap add name tap0 mode tap
$ sudo ip link set tap0 up
$ sudo ip link add name service type bridge
$ sudo ip link set service up
$ sudo ip link set tap0 master service
$ sudo ip addr add 10.0.0.1/24 dev service
```

And we're launching our unikernel!

```shell
$ solo5-hvt --net:service=tap0 --block:immuable=pack.pack -- \
  $(which immuable.hvt) --ipv4=10.0.0.2/24 &
$ PID=$!
$ curl http://10.0.0.2/
<html>
<head>
<title>My super website</title>
</head>
<body>
<h1 id="hello-world">
  <a class="anchor" aria-hidden="true" href="#hello-world"></a>Hello World!
</h1>
<p>This is my super website as an unikernel!</p>
 
</body>
</html>
$ kill -9 $PID
```

:::

There you go! As you can see, Immuable is quite simple because it provides both
the unikernel and the tool for generating the archive. In this case, `immuable`
does much more than simply _pack_ the files; it also attempts to recognise the
MIME type of the files so that the unikernel does not have to do this work: in
other words, the MIME types of the files are pre-calculated so that the
unikernel can send the correct `Content-Type`.

You can, in fact, test this recognition using `immuable mime <file>`. This
recognition is also carried out in OCaml using the [`conan`][conan] library.

```shell
$ immuable mime _www/index.html
text/html
```

Finally, to demonstrate just how powerful this approach is: the website is
currently generated by YOCaml and is available via `immuable`!

[github]: https://github.com/dinosaure/immuable
[yocaml]: https://github.com/xhtmlboi/yocaml
[opam]: https://opam.ocaml.org/
[jingoo]: https://github.com/tategakibunko/jingoo
[yocaml-tutorial]: https://yocaml.github.io/tutorial/index.html
[mnet]: /mnet/
[conan]: https://github.com/mirage/conan
