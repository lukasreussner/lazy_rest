import lazy_rest_pkg/lrstgen, os, lazy_rest_pkg/lrst, strutils,
  parsecfg, subexes, strtabs, streams, times, cgi, logging,
  external/badger_bits/bb_system

## Main API of `lazy_rest <https://github.com/gradha/lazy_rest>`_.

# THIS BLOCK IS PENDING https://github.com/gradha/lazy_rest/issues/5
# If you want to use the multi processor aware queues, which are able to
# render rst files using all the cores of your CPU, import
# `lazy_rest_pkg/lqueues.nim <lazy_rest_pkg/lqueues.html>`_ and use the
# objects and procs it provides.

proc tuple_to_version(x: expr): string {.compileTime.} =
  ## Transforms an arbitrary int tuple into a dot separated string.
  result = ""
  for name, value in x.fieldPairs: result.add("." & $value)
  if result.len > 0: result.delete(0, 0)

proc load_config*(mem_string: string): PStringTable


const
  rest_default_config = slurp("resources"/"embedded_nimdoc.cfg")
  error_template = slurp("resources"/"error_html.template") ##
  ## The default error template which uses the subexes module for string
  ## replacements.
  safe_error_start = slurp("resources"/"safe_error_start.template") ##
  ## Alternative to `error_template` if something goes wrong. This uses simple
  ## concatenation, so it should be safe.
  safe_error_end = slurp("resources"/"safe_error_end.template") ##
  ## Required pair to `safe_error_start`. Content is sandwiched between.
  prism_js = "<script>" & slurp("resources"/"prism.js") & "</script>"
  prism_css = slurp("resources"/"prism.css")
  version_int* = (major: 0, minor: 1, maintenance: 0) ## \
  ## Module version as an integer tuple.
  ##
  ## Major versions changes mean a break in API backwards compatibility, either
  ## through removal of symbols or modification of their purpose.
  ##
  ## Minor version changes can add procs (and maybe default parameters). Minor
  ## odd versions are development/git/unstable versions. Minor even versions
  ## are public stable releases.
  ##
  ## Maintenance version changes mean I'm not perfect yet despite all the kpop
  ## I watch.
  version_str* = tuple_to_version(version_int) ## \
    ## Module version as a string. Something like ``1.9.2``.

type
  Global_state = object
    default_config: PStringTable ## HTML rendering configuration, never nil.
    last_c_conversion: string ## Modified by the exported C API procs.
    did_start_logger: bool ## Internal debugging witness.


var G: Global_state
# Load default configuration.
G.default_config = load_config(rest_default_config)


proc load_config*(mem_string: string): PStringTable =
  ## Parses the configuration and returns it as a PStringTable.
  ##
  ## If something goes wrong, will likely raise an exception or return nil.
  var
    f = newStringStream(mem_string)
    temp = newStringTable(modeStyleInsensitive)
  if f.is_nil: raise newException(EInvalidValue, "cannot stream string")

  var p: TCfgParser
  open(p, f, "static slurped config")
  while true:
    var e = next(p)
    case e.kind
    of cfgEof:
      break
    of cfgSectionStart:   ## a ``[section]`` has been parsed
      discard
    of cfgKeyValuePair:
      temp[e.key] = e.value
    of cfgOption:
      warn("command: " & e.key & ": " & e.value)
    of cfgError:
      error(e.msg)
      raise newException(EInvalidValue, e.msg)
  close(p)
  result = temp


proc parse_rst_options*(options: string): PStringTable {.raises: [].} =
  ## Parses the options, returns nil if something goes wrong.
  ##
  ## You can safely pass the result of this proc to `rst_string_to_html
  ## <#rst_string_to_html>`_ since it will handle nil gracefully.
  if options.is_nil or options.len < 1:
    return nil

  try:
    # Select the correct configuration.
    result = load_config(options)
  except EInvalidValue, E_Base:
    try: error("Returning nil as parsed options")
    except: discard


proc debug_find_file(current, filename: string): string =
  ## Small wrapper around default file handler to debug paths.
  debug("Asking for '" & filename & "'")
  debug("Global is '" & current.parent_dir & "'")
  result = current.parent_dir / filename
  if result.exists_file:
    debug("Returning '" & result & "'")
    return
  else:
    result = ""


proc rst_string_to_html*(content, filename: string,
    config: PStringTable = nil): string =
  ## Converts a content named filename into a string with HTML tags.
  ##
  ## If there is any problem with the parsing, an exception could be thrown.
  ##
  ## You can pass nil as `config` if you want to use the default HTML rendering
  ## templates embedded in the module. Or you can load a configuration file
  ## with `parse_rst_options <#parse_rst_options>`_ or `load_config
  ## <#load_config>`_.  The value for the `config` parameter is explained in
  ## `lazy_rest/lrstgen.initRstGenerator()
  ## <lazy_rest_pkg/lrstgen.html#initRstGenerator>`_.
  assert content.not_nil
  assert G.default_config.not_nil
  let
    parse_options = {roSupportRawDirective}
    config = if config.not_nil: config else: G.default_config
  var
    filename = filename
    GENERATOR: TRstGenerator
    HAS_TOC: bool
  assert config.not_nil
  if filename.is_nil:
    filename = "(no filename)"

  # Was the debug logger started?
  if not G.did_start_logger:
    when not defined(release):
      var F = newFileLogger("/tmp/rester.log", fmtStr = verboseFmtStr)
      handlers.add(newConsoleLogger())
      handlers.add(F)
      info("Initiating global log for debugging")
    G.did_start_logger = true

  GENERATOR.initRstGenerator(outHtml, config, filename, parse_options,
    debug_find_file, lrst.defaultMsgHandler)

  # Parse the result.
  var RST = rstParse(content, filename, 1, 1, HAS_TOC,
    parse_options, debug_find_file)
  RESULT = newStringOfCap(30_000)

  # Render document into HTML chunk.
  var MOD_DESC = newStringOfCap(30_000)
  GENERATOR.renderRstToOut(RST, MOD_DESC)
  #GENERATOR.modDesc = toRope(MOD_DESC)

  var
    last_mod = epoch_time().from_seconds
    title = GENERATOR.meta[metaTitle]
  # Try to get filename modification, might not be possible with string data!
  if filename.not_nil:
    try: last_mod = filename.getLastModificationTime
    except: discard
  let
    last_mod_local = last_mod.getLocalTime
    last_mod_gmt = last_mod.getGMTime
  #if title.len < 1: title = filename.split_path.tail

  # Now finish by adding header, CSS and stuff.
  result = subex(config["doc.file"]) % ["title", title,
    "date", last_mod_gmt.format("yyyy-MM-dd"),
    "time", last_mod_gmt.format("HH:mm"),
    "local_date", last_mod_local.format("yyyy-MM-dd"),
    "local_time", last_mod_local.format("HH:mm"),
    "fileTime", $(int(last_mod_local.timeInfoToTime) * 1000),
    "prism_js", if GENERATOR.unknownLangs: prism_js else: "",
    "prism_css", if GENERATOR.unknownLangs: prism_css else: "",
    "content", MOD_DESC]


template rassert*(cond: bool, msg: string, body: stmt) {.immediate.} =
  ## Mix between assertion in debug mode and normal if at runtime.
  ##
  ## This *runtime* assert will stop execution in debug builds. In release
  ## builds `body` will be run, which can usually contain a return to avoid
  ## crashing further down the road.
  when defined(release):
    if not(cond):
      body
  else:
    assert(cond, msg)


proc rst_file_to_html*(filename: string, config: PStringTable = nil): string =
  ## Converts a filename with rest content into a string with HTML tags.
  ##
  ## If there is any problem with the parsing, an exception could be thrown.
  const msg = "filename parameter can't be nil!"
  rassert filename.not_nil, msg:
    raise new_exception(EInvalidValue, msg)

  result = rst_string_to_html(readFile(filename), filename, config)


proc add_pre_number_lines(content: string): string =
  ## Takes all the content and prefixes with number lines.
  ##
  ## The prefixing is done with plain text characters, right aligned, so this
  ## presumes the text will be formated with monospaced font inside some <pre>
  ## tag.
  let
    max_lines = 1 + content.count_lines
    width = len($max_lines)
  result = new_string_of_cap(content.len + width * max_lines)
  var
    I = 0
    LINE = 1
  result.add(align($LINE, width))
  result.add(" ")

  while I < content.len - 1:
    result.add(content[I])
    case content[I]
    of new_lines:
      if content[I] == '\c' and content[I+1] == '\l': inc I
      LINE.inc
      result.add(align($LINE, width))
      result.add(" ")
    else: discard
    inc I

  # Last character.
  if content[<content.len] in new_lines:
    discard
  else:
    result.add(content[<content.len])


proc build_error_table(ERRORS: ptr seq[string]): string {.raises: [].} =
  ## Returns a string with HTML to display the list of errors as a table.
  ##
  ## If there is any problem with the `ERRORS` variable an empty string is
  ## returned.
  RESULT = ""
  if ERRORS.not_nil and ERRORS[].not_nil and ERRORS[].len > 0:
    RESULT.add("<table CELLPADDING=\"5pt\" border=\"1\">")
    for line in ERRORS[]:
      RESULT.add("<tr><td>" & line.xml_encode & "</td></tr>")
    RESULT.add("</table>\n")


proc append(ERRORS: ptr seq[string], e: ref E_Base)
    {.raises: [].} =
  ## Helper to append the current exception to `ERRORS`.
  ##
  ## `ERRORS` can be nil, in which case this doesn't do anything. The exception
  ## will be added to the list as a basic text message.
  assert ERRORS.not_nil, "`ERRORS` ptr should never be nil, bad programmer!"
  assert ERRORS[].not_nil, "`ERRORS[]` should never be nil, bad programmer!"
  assert e.not_nil, "`e` ref should never be nil, bad programmer!"
  if ERRORS.is_nil or e.is_nil or ERRORS[].is_nil: return
  # Figure out the name of the exception.
  var E_NAME: string
  if e of EOS: E_NAME = "EOS"
  elif e of EIO: E_NAME = "EIO"
  elif e of EOutOfMemory: E_NAME = "EOutOfMemory"
  elif e of EInvalidSubex: E_NAME = "EInvalidSubex"
  elif e of EInvalidIndex: E_NAME = "EInvalidIndex"
  elif e of EInvalidValue: E_NAME = "EInvalidValue"
  elif e of EOutOfRange: E_NAME = "EOutOfRange"
  else:
    E_NAME = "E_Base(" & repr(e) & ")"
  ERRORS[].add(E_NAME & ", " & e.msg.safe)


template append_error_to_list(): stmt =
  ## Template to be used in exception blocks of procs using errors pattern.
  ##
  ## The template will expand to create a default errors variable which shadows
  ## the parameter. If the parameter has the default nil value, the local
  ## shadowed version will create local storage to be able to catch and process
  ## exceptions.
  ##
  ## This template should be used at the highest possible caller level, so that
  ## all its children are able to use the parent's error sequence rather than
  ## creating their own copy which goes nowhere.
  var
    ERRORS {.inject.} = ERRORS
    local {.inject.}: seq[string]
  if ERRORS.is_nil:
    local = @[]
    ERRORS = local.addr
  let e = get_current_exception()
  if e.not_nil:
    ERRORS.append(e)


proc build_error_html(filename, data: string, ERRORS: ptr seq[string]):
    string {.raises: [].} =
  ## Helper which builds an error HTML from the input data and collected errors.
  ##
  ## This proc always returns a valid HTML. All the input parameters are
  ## optional, the proc will figure what to do if they aren't present.
  result = ""
  var
    TIME_STR: array[4, string] # String representations, date, then time.
    ERROR_TITLE = "Error processing "
  # Force initialization to empty strings for time representations.
  for f in 0 .. high(TIME_STR):
    TIME_STR[f] = ""

  # Fixup title page as much as we can.
  if filename.is_nil:
    if data.is_nil:
      ERROR_TITLE.add("rst input")
    else:
      ERROR_TITLE.add($data.len & " bytes of rst input")
  else:
    ERROR_TITLE.add(filename.xml_encode)

  # Recover current time and store in text for string replacement.
  try:
    for f, value in [get_time().get_gm_time, get_time().get_local_time]:
      TIME_STR[f * 2] = value.format("yyyy-MM-dd")
      TIME_STR[f * 2 + 1] = value.format("HH:mm")
  except EInvalidValue:
    discard

  # Generate content for the error HTML page.
  var CONTENT = ""
  if data.not_nil and data.len > 0:
    CONTENT = "<p><pre>" &
      data.xml_encode.add_pre_number_lines.replace("\n", "<br>") &
      "</pre></p>"

  # Attempt the replacement.
  try:
    result = subex(error_template) % ["title", ERROR_TITLE,
      "local_date", TIME_STR[2], "local_time", TIME_STR[3],
      "version_str", version_str, "errors", ERRORS.build_error_table,
      "content", CONTENT]
  except:
    ERRORS.append(get_current_exception())

  if result.len < 1:
    # Oops, something went really wrong and we don't have yet the HTML. Build
    # it from simple string concatenation.
    result = safe_error_start & ERRORS.build_error_table & "<br>" &
      CONTENT & safe_error_end


proc safe_rst_string_to_html*(filename, data: string,
    ERRORS: ptr seq[string] = nil, config: PStringTable = nil):
    string {.raises: [].} =
  ## Wrapper over `rst_string_to_html <#rst_string_to_html>`_ to catch
  ## exceptions.
  ##
  ## Returns always a valid HTML. If something bad happens, it tries to show
  ## the error for debugging but still returns valid HTML, though it may be
  ## quite different from what you expect. The `filename` parameter is only
  ## used for error reporting, you can pass nil or the empty string.
  ##
  ## This proc always returns without raising any exceptions, but if you want
  ## to know about errors you can pass an initialized sequence of string as the
  ## `ERRORS` parameter to figure out why something fails and report it to the
  ## user. Any problems found during rendering will be added to the existing
  ## list.
  ##
  ## The value for the `config` parameter is explained in
  ## `lazy_rest/lrstgen.initRstGenerator()
  ## <lazy_rest_pkg/lrstgen.html#initRstGenerator>`_.
  ##
  ## Usage example:
  ##
  ## .. code-block:: nimrod
  ##
  ##   echo safe_rst_string_to_html(nil, rst)
  ##   # --> dumps HTML saying something bad happened.
  ##   var ERRORS: seq[string] = @[]
  ##   let html = safe_rst_string_to_html(name, rst, ERRORS.addr)
  ##   if ERRORS.len > 0:
  ##     # We got HTML, but it it won't be nice.
  ##     for error in ERRORS: echo error
  ##     ...
  ##   else:
  ##     # Yay, use `html` without worries.
  const msg = "data parameter can't be nil"
  rassert data.not_nil, msg:
    append_error_to_list()
    ERRORS.append(new_exception(EInvalidValue, msg))
    result = build_error_html(filename, data, ERRORS)
    return

  try:
    result = rst_string_to_html(data, filename, config)
  except:
    append_error_to_list()
    result = build_error_html(filename, data, ERRORS)


proc safe_rst_file_to_html*(filename: string, ERRORS: ptr seq[string] = nil,
    config: PStringTable = nil): string {.raises: [].} =
  ## Wrapper over `rst_file_to_html <#rst_file_to_html>`_ to catch exceptions.
  ##
  ## Returns always a valid HTML. If something bad happens, it tries to show
  ## the error for debugging but still returns valid HTML, though it may be
  ## quite different from what you expect.
  ##
  ## This proc always returns without raising any exceptions, but if you want
  ## to know about errors you can pass an initialized sequence of string as the
  ## `ERRORS` parameter to figure out why something fails and report it to the
  ## user. Any problems found during rendering will be added to the existing
  ## list.
  ##
  ## The value for the `config` parameter is explained in
  ## `lazy_rest/lrstgen.initRstGenerator()
  ## <lazy_rest_pkg/lrstgen.html#initRstGenerator>`_.
  ##
  ## Usage example:
  ##
  ## .. code-block:: nimrod
  ##
  ##   import os
  ##
  ##   echo safe_rst_file_to_html(nil)
  ##   # --> dumps HTML saying something bad happened.
  ##   var ERRORS: seq[string] = @[]
  ##   let html = safe_rst_file_to_html(filename, ERRORS.addr)
  ##   if ERRORS.len > 0:
  ##     # We got HTML, but it it won't be nice.
  ##     for error in ERRORS: echo error
  ##     ...
  ##   else:
  ##     filename.change_file_ext("html").write_file(html)
  try:
    result = rst_file_to_html(filename, config)
  except:
    append_error_to_list()
    var CONTENT: string
    try:
      if filename.not_nil:
        CONTENT = filename.read_file
    except:
      CONTENT = "Could not read " & filename & " for display!!!"
    result = build_error_html(filename, CONTENT, ERRORS)


proc nim_file_to_html*(filename: string, number_lines = true,
    config: PStringTable = nil): string {.raises: [].} =
  ## Puts the contents of `filename` in a code block to render as rest.
  ##
  ## Returns a string with the rendered HTML. The `number_lines` parameter
  ## controls if the rendered source will have a column to the left of the
  ## source with line numbers. By default source lines will be numbered.
  ##
  ## This proc always works, since even empty code blocks should render (as
  ## empty HTML), and there should be no content escaping problems. In the case
  ## of failure, the error itself will be rendered in the final HTML.
  const
    with_numbers = "\n.. code-block:: nimrod\n   :number-lines:\n\n  "
    without_numbers = "\n.. code-block:: nimrod\n  "
  try:
    let
      name = filename.splitFile.name
      title_symbols = repeatChar(name.len, '=')
      length = 1000 + int(filename.getFileSize)
    var SOURCE = newStringOfCap(length)
    SOURCE = title_symbols & "\n" & name & "\n" & title_symbols &
      (if number_lines: with_numbers else: without_numbers)
    SOURCE.add(readFile(filename).replace("\n", "\n  "))
    result = rst_string_to_html(SOURCE, filename, config)
  except E_Base:
    result = "<html><body><h1>Error for " & filename & "</h1></body></html>"
  except EOS:
    result = "<html><body><h1>OS error for " & filename & "</h1></body></html>"
  except EIO:
    result = "<html><body><h1>I/O error for " & filename & "</h1></body></html>"
  except EOutOfMemory:
    result = """<html><body><h1>Out of memory!</h1></body></html>"""


proc txt_to_rst*(input_filename: cstring): int {.exportc, raises: [].}=
  ## Converts the input filename.
  ##
  ## The conversion is stored in internal global variables. The proc returns
  ## the number of bytes required to store the generated HTML, which you can
  ## obtain using the global accessor getHtml passing a pointer to the buffer.
  ##
  ## The returned value doesn't include the typical C null terminator. If there
  ## are problems, an internal error text may be returned so it can be
  ## displayed to the end user. As such, it is impossible to know the
  ## success/failure based on the returned value.
  ##
  ## This proc is mainly for the C api.
  assert input_filename.not_nil
  let filename = $input_filename
  case filename.splitFile.ext
  of ".nim":
    G.last_c_conversion = nim_file_to_html(filename)
  else:
    G.last_c_conversion = safe_rst_file_to_html(filename)
  result = G.last_c_conversion.len


proc get_global_html*(output_buffer: pointer) {.exportc, raises: [].} =
  ## Copies the result of txt_to_rst into output_buffer.
  ##
  ## If output_buffer doesn't contain the bytes returned by txt_to_rst, you
  ## will pay that dearly!
  ##
  ## This proc is mainly for the C api.
  if G.last_c_conversion.is_nil:
    quit("Uh oh, wrong API usage")
  copyMem(output_buffer, addr(G.last_c_conversion[0]), G.last_c_conversion.len)


#when isMainModule:
#  writeFile("out.html", rst_file_to_html("test.rst"))
