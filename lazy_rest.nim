import lazy_rest_pkg/lrstgen, os, lazy_rest_pkg/lrst, strutils,
  parsecfg, subexes, strtabs, streams, times, cgi, logging,
  external/badger_bits/bb_system

## Main API of `lazy_rest <https://github.com/gradha/lazy_rest>`_.

proc tuple_to_version(x: expr): string {.compileTime.} =
  ## Transforms an arbitrary int tuple into a dot separated string.
  result = ""
  for name, value in x.fieldPairs: result.add("." & $value)
  if result.len > 0: result.delete(0, 0)

const
  rest_default_config = slurp("resources"/"embedded_nimdoc.cfg")
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
    config: PStringTable ## HTML rendering configuration, nil unless loaded.
    last_c_conversion: string ## Modified by the exported C API procs.

var G: Global_state

proc loadConfig(mem_string: string): PStringTable =
  ## Parses the configuration and retuns it as a PStringTable.
  ##
  ## If something goes wrong, will likely raise an exception. Otherwise it
  ## always return a valid object.
  result = newStringTable(modeStyleInsensitive)
  var f = newStringStream(mem_string)
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
      result[e.key] = e.value
    of cfgOption:
      warn("command: " & e.key & ": " & e.value)
    of cfgError:
      error(e.msg)
      raise newException(EInvalidValue, e.msg)
  close(p)

proc change_rst_options*(options: string): bool {.discardable, raises: [].} =
  ## Changes the current global options.
  ##
  ## If you pass nil, or the configuration you pass is invalid and raises some
  ## parsing exception, the proc will modify the global options to sane
  ## defaults. Otherwise future calls to rst parsing will use the new
  ## templates. See rstgen.defaultConfig() for information on this.
  ##
  ## Returns true if `options` was set successfully, false otherwise. Note that
  ## if you are passing nil to reset the options this proc always returns
  ## false.
  try:
    # Select the correct configuration.
    let o = if options.is_nil: rest_default_config else: options
    G.config = loadConfig(o)
    # But report success only if a valid config was passed in.
    if options.not_nil:
      result = true
  except EInvalidValue, E_Base:
    try: error("Setting default rst options")
    except: discard
    try: G.config = loadConfig(rest_default_config)
    except: discard

proc rst_string_to_html*(content, filename: string): string =
  ## Converts a content named filename into a string with HTML tags.
  ##
  ## If there is any problem with the parsing, an exception could be thrown.
  ## Note that this proc depends on global variables, you can't run safely
  ## multiple instances of it.
  let
    parse_options = {roSupportRawDirective}
  var
    GENERATOR: TRstGenerator
    HAS_TOC: bool

  # Was the global configuration already loaded?
  if G.config.is_nil:
    when not defined(release):
      var f = newFileLogger("/tmp/rester.log", fmtStr = verboseFmtStr)
      handlers.add(newConsoleLogger())
      handlers.add(f)
      info("Initiating global log for debugging")
    G.config = loadConfig(rest_default_config)
  assert G.config.not_nil

  proc myFindFile(current, filename: string): string =
    debug("Asking for '" & filename & "'")
    debug("Global is '" & current.parent_dir & "'")
    result = current.parent_dir / filename
    if result.exists_file:
      debug("Returning '" & result & "'")
      return
    else:
      result = ""

  GENERATOR.initRstGenerator(outHtml, G.config, filename, parse_options,
    myFindFile, lrst.defaultMsgHandler)

  # Parse the result.
  var RST = rstParse(content, filename, 1, 1, HAS_TOC,
    parse_options, myFindFile)
  RESULT = newStringOfCap(30_000)

  # Render document into HTML chunk.
  var MOD_DESC = newStringOfCap(30_000)
  GENERATOR.renderRstToOut(RST, MOD_DESC)
  #GENERATOR.modDesc = toRope(MOD_DESC)

  let
    last_mod = filename.getLastModificationTime
    last_mod_local = last_mod.getLocalTime
    last_mod_gmt = last_mod.getGMTime
  var title = GENERATOR.meta[metaTitle]
  #if title.len < 1: title = filename.split_path.tail

  # Now finish by adding header, CSS and stuff.
  result = subex(G.config["doc.file"]) % ["title", title,
    "date", last_mod_gmt.format("yyyy-MM-dd"),
    "time", last_mod_gmt.format("HH:mm"),
    "local_date", last_mod_local.format("yyyy-MM-dd"),
    "local_time", last_mod_local.format("HH:mm"),
    "fileTime", $(int(last_mod_local.timeInfoToTime) * 1000),
    "prism_js", if GENERATOR.unknownLangs: prism_js else: "",
    "prism_css", if GENERATOR.unknownLangs: prism_css else: "",
    "content", MOD_DESC]


proc rst_file_to_html*(filename: string): string =
  ## Converts a filename with rest content into a string with HTML tags.
  ##
  ## If there is any problem with the parsing, an exception could be thrown.
  ## Note that this proc depends on global variables, you can't run safely
  ## multiple instances of it.
  return rst_string_to_html(readFile(filename), filename)


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


proc safe_rst_file_to_html*(filename: string): string {.raises: [].} =
  ## Wrapper over rst_file_to_html to catch exceptions.
  ##
  ## If something bad happens, it tries to show the error for debugging but
  ## still returns a sort of valid HTML embedded code.
  try:
    result = rst_file_to_html(filename)
  except:
    var content: string
    try: content = readFile(filename).XMLEncode
    except E_Base: content = "Could not read " & filename & "!!!"
    let
      e = getCurrentException()
      msg = getCurrentExceptionMsg()
    result = "<html><body><b>Sorry! Error parsing " & filename.XMLEncode &
      " with version " & version_str &
      """.</b><p>If possible please report it at <a href="""" &
      """https://github.com/gradha/quicklook-rest-with-nimrod/issues">""" &
      "https://github.com/gradha/quicklook-rest-with-nimrod/issues</a>" &
      "<p>" & repr(e).XMLEncode & " with message '" &
      msg.XMLEncode & "'</p><p>Displaying raw contents of file anyway:</p>" &
      "<p><pre>" & content.add_pre_number_lines.replace("\n", "<br>") &
      "</pre></p></body></html>"

proc nim_file_to_html*(filename: string): string {.raises: [].} =
  ## Puts filename into a code block and renders like rst file.
  ##
  ## This proc always works, since even empty code blocks should render (as
  ## empty HTML), and there should be no content escaping problems.
  try:
    let
      name = filename.splitFile.name
      title_symbols = repeatChar(name.len, '=')
      length = 1000 + int(filename.getFileSize)
    var source = newStringOfCap(length)
    source = title_symbols & "\n" & name & "\n" & title_symbols &
      "\n.. code-block:: nimrod\n  "
    source.add(readFile(filename).replace("\n", "\n  "))
    result = rst_string_to_html(source, filename)
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
