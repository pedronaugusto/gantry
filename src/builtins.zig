//! The modules each language's own distribution provides, so that an
//! import of one is no dependency. Generated from Node 22.23
//! `module.builtinModules`, Python 3.13 `sys.stdlib_module_names`, the
//! modules on Nim 2.2.10's default search paths, and the packages the
//! `java.*` and `jdk.*` modules of Java SE 21 export outside `java.` and
//! `jdk.`. A later release can add names; a dependency rule's `ignore`
//! takes them meanwhile.
const std = @import("std");

/// Node modules, top-level names; `node:` names are builtins whatever follows.
pub const node = std.StaticStringMap(void).initComptime(.{
    .{"assert"},       .{"async_hooks"},         .{"buffer"}, .{"child_process"},  .{"cluster"}, .{"console"},        .{"constants"},
    .{
        "crypto",
    },
    .{"dgram"},        .{"diagnostics_channel"}, .{"dns"},    .{"domain"},         .{"events"},  .{"fs"},             .{"http"},
    .{"http2"},
    .{
        "https",
    },
    .{"inspector"},    .{"module"},              .{"net"},    .{"os"},             .{"path"},    .{"perf_hooks"},     .{"process"},
    .{"punycode"},
    .{
        "querystring",
    },
    .{"readline"},     .{"repl"},                .{"stream"}, .{"string_decoder"}, .{"sys"},     .{"timers"},         .{"tls"},
    .{"trace_events"},
    .{
        "tty",
    },
    .{"url"},          .{"util"},                .{"v8"},     .{"vm"},             .{"wasi"},    .{"worker_threads"}, .{"zlib"},
});
/// Python standard library top-level modules.
pub const python = std.StaticStringMap(void).initComptime(.{
    .{"__future__"},                 .{"_abc"},          .{"_aix_support"},    .{"_android_support"}, .{"_apple_support"},   .{"_ast"},
    .{
        "_asyncio",
    },
    .{"_bisect"},                    .{"_blake2"},       .{"_bz2"},            .{"_codecs"},          .{"_codecs_cn"},       .{"_codecs_hk"},
    .{
        "_codecs_iso2022",
    },
    .{"_codecs_jp"},                 .{"_codecs_kr"},    .{"_codecs_tw"},      .{"_collections"},     .{"_collections_abc"},
    .{
        "_colorize",
    },
    .{"_compat_pickle"},             .{"_compression"},  .{"_contextvars"},    .{"_csv"},             .{"_ctypes"},          .{"_curses"},
    .{
        "_curses_panel",
    },
    .{"_datetime"},                  .{"_dbm"},          .{"_decimal"},        .{"_elementtree"},
    .{
        "_frozen_importlib",
    },
    .{"_frozen_importlib_external"}, .{"_functools"},    .{"_gdbm"},           .{"_hashlib"},         .{"_heapq"},
    .{
        "_imp",
    },
    .{"_interpchannels"},            .{"_interpqueues"}, .{"_interpreters"},   .{"_io"},              .{"_ios_support"},     .{"_json"},
    .{
        "_locale",
    },
    .{"_lsprof"},                    .{"_lzma"},         .{"_markupbase"},     .{"_md5"},             .{"_multibytecodec"},  .{"_multiprocessing"},
    .{
        "_opcode",
    },
    .{"_opcode_metadata"},           .{"_operator"},     .{"_osx_support"},    .{"_overlapped"},      .{"_pickle"},
    .{
        "_posixshmem",
    },
    .{"_posixsubprocess"},           .{"_py_abc"},       .{"_pydatetime"},     .{"_pydecimal"},       .{"_pyio"},            .{"_pylong"},
    .{
        "_pyrepl",
    },
    .{"_queue"},                     .{"_random"},       .{"_scproxy"},        .{"_sha1"},            .{"_sha2"},            .{"_sha3"},
    .{"_signal"},
    .{
        "_sitebuiltins",
    },
    .{"_socket"},                    .{"_sqlite3"},      .{"_sre"},            .{"_ssl"},             .{"_stat"},            .{"_statistics"},
    .{"_string"},
    .{
        "_strptime",
    },
    .{"_struct"},                    .{"_suggestions"},  .{"_symtable"},       .{"_sysconfig"},       .{"_thread"},          .{"_threading_local"},
    .{
        "_tkinter",
    },
    .{"_tokenize"},                  .{"_tracemalloc"},  .{"_typing"},         .{"_uuid"},            .{"_warnings"},        .{"_weakref"},
    .{
        "_weakrefset",
    },
    .{"_winapi"},                    .{"_wmi"},          .{"_zoneinfo"},       .{"abc"},              .{"antigravity"},      .{"argparse"},
    .{"array"},                      .{"ast"},
    .{
        "asyncio",
    },
    .{"atexit"},                     .{"base64"},        .{"bdb"},             .{"binascii"},         .{"bisect"},           .{"builtins"},
    .{"bz2"},                        .{"cProfile"},
    .{
        "calendar",
    },
    .{"cmath"},                      .{"cmd"},           .{"code"},            .{"codecs"},           .{"codeop"},           .{"collections"},
    .{"colorsys"},
    .{
        "compileall",
    },
    .{"concurrent"},                 .{"configparser"},  .{"contextlib"},      .{"contextvars"},      .{"copy"},             .{"copyreg"},
    .{"csv"},
    .{
        "ctypes",
    },
    .{"curses"},                     .{"dataclasses"},   .{"datetime"},        .{"dbm"},              .{"decimal"},          .{"difflib"},
    .{"dis"},                        .{"doctest"},
    .{
        "email",
    },
    .{"encodings"},                  .{"ensurepip"},     .{"enum"},            .{"errno"},            .{"faulthandler"},     .{"fcntl"},
    .{"filecmp"},
    .{
        "fileinput",
    },
    .{"fnmatch"},                    .{"fractions"},     .{"ftplib"},          .{"functools"},        .{"gc"},               .{"genericpath"},
    .{"getopt"},
    .{
        "getpass",
    },
    .{"gettext"},                    .{"glob"},          .{"graphlib"},        .{"grp"},              .{"gzip"},             .{"hashlib"},
    .{"heapq"},                      .{"hmac"},          .{"html"},
    .{
        "http",
    },
    .{"idlelib"},                    .{"imaplib"},       .{"importlib"},       .{"inspect"},          .{"io"},               .{"ipaddress"},
    .{"itertools"},                  .{"json"},
    .{
        "keyword",
    },
    .{"linecache"},                  .{"locale"},        .{"logging"},         .{"lzma"},             .{"mailbox"},          .{"marshal"},
    .{"math"},                       .{"mimetypes"},
    .{
        "mmap",
    },
    .{"modulefinder"},               .{"msvcrt"},        .{"multiprocessing"}, .{"netrc"},            .{"nt"},               .{"ntpath"},
    .{"nturl2path"},
    .{
        "numbers",
    },
    .{"opcode"},                     .{"operator"},      .{"optparse"},        .{"os"},               .{"pathlib"},          .{"pdb"},
    .{"pickle"},                     .{"pickletools"},
    .{
        "pkgutil",
    },
    .{"platform"},                   .{"plistlib"},      .{"poplib"},          .{"posix"},            .{"posixpath"},        .{"pprint"},
    .{"profile"},                    .{"pstats"},
    .{
        "pty",
    },
    .{"pwd"},                        .{"py_compile"},    .{"pyclbr"},          .{"pydoc"},            .{"pydoc_data"},       .{"pyexpat"},
    .{"queue"},                      .{"quopri"},
    .{
        "random",
    },
    .{"re"},                         .{"readline"},      .{"reprlib"},         .{"resource"},         .{"rlcompleter"},      .{"runpy"},
    .{"sched"},                      .{"secrets"},
    .{
        "select",
    },
    .{"selectors"},                  .{"shelve"},        .{"shlex"},           .{"shutil"},           .{"signal"},           .{"site"},
    .{"smtplib"},                    .{"socket"},
    .{
        "socketserver",
    },
    .{"sqlite3"},                    .{"sre_compile"},   .{"sre_constants"},   .{"sre_parse"},        .{"ssl"},              .{"stat"},
    .{"statistics"},
    .{
        "string",
    },
    .{"stringprep"},                 .{"struct"},        .{"subprocess"},      .{"symtable"},         .{"sys"},              .{"sysconfig"},
    .{"syslog"},
    .{
        "tabnanny",
    },
    .{"tarfile"},                    .{"tempfile"},      .{"termios"},         .{"textwrap"},         .{"this"},             .{"threading"},
    .{"time"},                       .{"timeit"},
    .{
        "tkinter",
    },
    .{"token"},                      .{"tokenize"},      .{"tomllib"},         .{"trace"},            .{"traceback"},        .{"tracemalloc"},
    .{"tty"},
    .{
        "turtle",
    },
    .{"turtledemo"},                 .{"types"},         .{"typing"},          .{"unicodedata"},      .{"unittest"},         .{"urllib"},
    .{"uuid"},
    .{
        "venv",
    },
    .{"warnings"},                   .{"wave"},          .{"weakref"},         .{"webbrowser"},       .{"winreg"},           .{"winsound"},
    .{"wsgiref"},                    .{"xml"},
    .{
        "xmlrpc",
    },
    .{"zipapp"},                     .{"zipfile"},       .{"zipimport"},       .{"zlib"},             .{"zoneinfo"},
});
/// Nim modules importable by bare name.
pub const nim = std.StaticStringMap(void).initComptime(.{
    .{"algorithm"},             .{"async"},                .{"asyncdispatch"},      .{"asyncfile"},    .{"asyncfutures"},
    .{
        "asynchttpserver",
    },
    .{"asyncjs"},               .{"asyncmacro"},           .{"asyncnet"},           .{"asyncstreams"}, .{"atomics"},
    .{"base64"},                .{"bitops"},
    .{
        "browsers",
    },
    .{"cgi"},                   .{"chains"},               .{"colors"},             .{"complex"},      .{"cookies"},
    .{"coro"},                  .{"cpuinfo"},              .{"cpuload"},
    .{
        "critbits",
    },
    .{"cstrutils"},             .{"deques"},               .{"distros"},            .{"dom"},          .{"dynlib"},
    .{"encodings"},             .{"endians"},              .{"epoll"},
    .{
        "fenv",
    },
    .{"future"},                .{"hashcommon"},           .{"hashes"},             .{"heapqueue"},    .{"hotcodereloading"},
    .{"htmlgen"},
    .{
        "htmlparser",
    },
    .{"httpclient"},            .{"httpcore"},             .{"inotify"},            .{"intsets"},      .{"jsconsole"},
    .{"jscore"},                .{"jsffi"},                .{"json"},
    .{
        "jsre",
    },
    .{"kqueue"},                .{"lenientops"},           .{"lexbase"},            .{"linenoise"},    .{"linux"},
    .{"lists"},                 .{"locks"},
    .{
        "logging",
    },
    .{"macrocache"},            .{"macros"},               .{"marshal"},            .{"math"},         .{"md5"},
    .{"memfiles"},              .{"mersenne"},
    .{
        "mimetypes",
    },
    .{"nativesockets"},         .{"net"},                  .{"nimhcr"},             .{"nimprof"},      .{"nimrtl"},
    .{"nre"},                   .{"oids"},                 .{"openssl"},
    .{
        "options",
    },
    .{"os"},                    .{"ospaths"},              .{"osproc"},             .{"oswalkdir"},    .{"parsecfg"},
    .{"parsecsv"},              .{"parsejson"},
    .{
        "parseopt",
    },
    .{"parsesql"},              .{"parseutils"},           .{"parsexml"},           .{"pathnorm"},     .{"pcre"},
    .{"pcre2"},                 .{"pegs"},
    .{
        "posix",
    },
    .{"posix_freertos_consts"}, .{"posix_haiku"},          .{"posix_linux_amd64"},
    .{
        "posix_linux_amd64_consts",
    },
    .{"posix_macos_amd64"},     .{"posix_nintendoswitch"},
    .{
        "posix_nintendoswitch_consts",
    },
    .{"posix_openbsd_amd64"},   .{"posix_other"},          .{"posix_other_consts"}, .{"posix_utils"},  .{"prelude"},
    .{
        "random",
    },
    .{"rationals"},             .{"rdstdin"},              .{"re"},                 .{"registry"},     .{"reservedmem"},
    .{"rlocks"},                .{"ropes"},
    .{
        "rtarrays",
    },
    .{"segfaults"},             .{"selectors"},            .{"sequtils"},           .{"setimpl"},      .{"sets"},
    .{"sharedlist"},
    .{
        "sharedtables",
    },
    .{"ssl_certs"},             .{"ssl_config"},           .{"stats"},              .{"streams"},      .{"streamwrapper"},
    .{"strformat"},
    .{
        "strmisc",
    },
    .{"strscans"},              .{"strtabs"},              .{"strutils"},           .{"sugar"},        .{"sums"},
    .{"system"},                .{"tableimpl"},            .{"tables"},
    .{
        "terminal",
    },
    .{"termios"},               .{"threadpool"},           .{"times"},              .{"tinyc"},        .{"typeinfo"},
    .{"typetraits"},            .{"unicode"},
    .{
        "unidecode",
    },
    .{"unittest"},              .{"uri"},                  .{"volatile"},           .{"winlean"},      .{"xmlparser"},
    .{"xmltree"},
});
/// JDK packages outside `java.` and `jdk.`, which are all the JDK's.
pub const java = std.StaticStringMap(void).initComptime(.{
    .{"com.sun.java.accessibility.util"}, .{"com.sun.jdi"},
    .{
        "com.sun.jdi.connect",
    },
    .{"com.sun.jdi.connect.spi"},         .{"com.sun.jdi.event"},
    .{"com.sun.jdi.request"},
    .{
        "com.sun.management",
    },
    .{"com.sun.net.httpserver"},          .{"com.sun.net.httpserver.spi"},
    .{"com.sun.nio.file"},
    .{
        "com.sun.nio.sctp",
    },
    .{"com.sun.security.auth"},           .{"com.sun.security.auth.callback"},
    .{
        "com.sun.security.auth.login",
    },
    .{"com.sun.security.auth.module"},    .{"com.sun.security.jgss"},
    .{
        "com.sun.source.doctree",
    },
    .{"com.sun.source.tree"},             .{"com.sun.source.util"},
    .{
        "com.sun.tools.attach",
    },
    .{"com.sun.tools.attach.spi"},        .{"com.sun.tools.javac"},
    .{
        "com.sun.tools.jconsole",
    },
    .{"javax.accessibility"},             .{"javax.annotation.processing"},
    .{"javax.crypto"},
    .{
        "javax.crypto.interfaces",
    },
    .{"javax.crypto.spec"},               .{"javax.imageio"},
    .{"javax.imageio.event"},
    .{
        "javax.imageio.metadata",
    },
    .{"javax.imageio.plugins.bmp"},       .{"javax.imageio.plugins.jpeg"},
    .{
        "javax.imageio.plugins.tiff",
    },
    .{"javax.imageio.spi"},               .{"javax.imageio.stream"},
    .{"javax.lang.model"},
    .{
        "javax.lang.model.element",
    },
    .{"javax.lang.model.type"},           .{"javax.lang.model.util"},
    .{
        "javax.management",
    },
    .{"javax.management.loading"},        .{"javax.management.modelmbean"},
    .{
        "javax.management.monitor",
    },
    .{"javax.management.openmbean"},      .{"javax.management.relation"},
    .{
        "javax.management.remote",
    },
    .{"javax.management.remote.rmi"},     .{"javax.management.timer"},
    .{
        "javax.naming",
    },
    .{"javax.naming.directory"},          .{"javax.naming.event"},
    .{"javax.naming.ldap"},
    .{
        "javax.naming.ldap.spi",
    },
    .{"javax.naming.spi"},                .{"javax.net"},
    .{"javax.net.ssl"},                   .{"javax.print"},
    .{
        "javax.print.attribute",
    },
    .{"javax.print.attribute.standard"},  .{"javax.print.event"},
    .{"javax.rmi.ssl"},
    .{
        "javax.script",
    },
    .{"javax.security.auth"},             .{"javax.security.auth.callback"},
    .{
        "javax.security.auth.kerberos",
    },
    .{"javax.security.auth.login"},       .{"javax.security.auth.spi"},
    .{
        "javax.security.auth.x500",
    },
    .{"javax.security.cert"},             .{"javax.security.sasl"},
    .{"javax.smartcardio"},
    .{
        "javax.sound.midi",
    },
    .{"javax.sound.midi.spi"},            .{"javax.sound.sampled"},
    .{"javax.sound.sampled.spi"},
    .{
        "javax.sql",
    },
    .{"javax.sql.rowset"},                .{"javax.sql.rowset.serial"},
    .{"javax.sql.rowset.spi"},
    .{
        "javax.swing",
    },
    .{"javax.swing.border"},              .{"javax.swing.colorchooser"},
    .{
        "javax.swing.event",
    },
    .{"javax.swing.filechooser"},         .{"javax.swing.plaf"},
    .{
        "javax.swing.plaf.basic",
    },
    .{"javax.swing.plaf.metal"},          .{"javax.swing.plaf.multi"},
    .{
        "javax.swing.plaf.nimbus",
    },
    .{"javax.swing.plaf.synth"},          .{"javax.swing.table"},
    .{"javax.swing.text"},
    .{
        "javax.swing.text.html",
    },
    .{"javax.swing.text.html.parser"},    .{"javax.swing.text.rtf"},
    .{"javax.swing.tree"},
    .{
        "javax.swing.undo",
    },
    .{"javax.tools"},                     .{"javax.transaction.xa"},
    .{"javax.xml"},                       .{"javax.xml.catalog"},
    .{
        "javax.xml.crypto",
    },
    .{"javax.xml.crypto.dom"},            .{"javax.xml.crypto.dsig"},
    .{
        "javax.xml.crypto.dsig.dom",
    },
    .{"javax.xml.crypto.dsig.keyinfo"},   .{"javax.xml.crypto.dsig.spec"},
    .{
        "javax.xml.datatype",
    },
    .{"javax.xml.namespace"},             .{"javax.xml.parsers"},
    .{"javax.xml.stream"},
    .{
        "javax.xml.stream.events",
    },
    .{"javax.xml.stream.util"},           .{"javax.xml.transform"},
    .{
        "javax.xml.transform.dom",
    },
    .{"javax.xml.transform.sax"},         .{"javax.xml.transform.stax"},
    .{
        "javax.xml.transform.stream",
    },
    .{"javax.xml.validation"},            .{"javax.xml.xpath"},
    .{"netscape.javascript"},
    .{
        "org.ietf.jgss",
    },
    .{"org.w3c.dom"},                     .{"org.w3c.dom.bootstrap"},
    .{"org.w3c.dom.css"},
    .{
        "org.w3c.dom.events",
    },
    .{"org.w3c.dom.html"},                .{"org.w3c.dom.ls"},
    .{"org.w3c.dom.ranges"},
    .{
        "org.w3c.dom.stylesheets",
    },
    .{"org.w3c.dom.traversal"},           .{"org.w3c.dom.views"},
    .{"org.w3c.dom.xpath"},
    .{
        "org.xml.sax",
    },
    .{"org.xml.sax.ext"},                 .{"org.xml.sax.helpers"},
    .{"sun.misc"},                        .{"sun.reflect"},
});
