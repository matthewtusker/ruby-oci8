begin
  require 'mkmf'
rescue LoadError
  if /linux/ =~ RUBY_PLATFORM
    raise <<EOS
You need to install a ruby development package ruby-devel, ruby-dev or so.
EOS
  end
  raise
end

require File.dirname(__FILE__) + '/oraconf'
require File.dirname(__FILE__) + '/apiwrap'

RUBY_OCI8_VERSION = File.read("#{File.dirname(__FILE__)}/../../VERSION").chomp

oraconf = OraConf.get()

def replace_keyword(source, target, replace)
  puts "creating #{target} from #{source}"
  open(source, "rb") { |f|
    buf = f.read
    replace.each do |key, value|
      buf.gsub!('@@' + key + '@@', value)
    end
    open(target, "wb") {|fw|
      fw.write buf
    }
  }        
end

$CFLAGS += oraconf.cflags
saved_libs = $libs
$libs += oraconf.libs

oci_actual_client_version = 0x08000000
funcs = {}
YAML.load(open(File.dirname(__FILE__) + '/apiwrap.yml')).each do |key, val|
  key = key[0..-4] if key[-3..-1] == '_nb'
  ver = val[:version]
  ver_major = (ver / 100)
  ver_minor = (ver / 10) % 10
  ver_update = ver % 10
  ver = ((ver_major << 24) | (ver_minor << 20) | (ver_update << 12))
  funcs[ver] ||= []
  funcs[ver] << key
end
funcs.keys.sort.each do |version|
  next if version == 0x08000000
  verstr = format('%d.%d.%d', ((version >> 24) & 0xFF), ((version >> 20) & 0xF), ((version >> 12) & 0xFF))
  puts "checking for Oracle #{verstr} API - start"
  result = catch :result do
    funcs[version].sort.each do |func|
      unless have_func(func)
        throw :result, "fail"
      end
    end
    oci_actual_client_version = version
    "pass"
  end
  puts "checking for Oracle #{verstr} API - #{result}"
  break if result == 'fail'
end

have_type('oratext', 'ociap.h')
have_type('OCIDateTime*', 'ociap.h')
have_type('OCIInterval*', 'ociap.h')
have_type('OCICallbackLobRead2', 'ociap.h')
have_type('OCICallbackLobWrite2', 'ociap.h')
have_type('OCIAdmin*', 'ociap.h')

if with_config('oracle-version')
  oci_client_version = with_config('oracle-version').to_i
else
  oci_client_version = oci_actual_client_version
end
$defs << "-DORACLE_CLIENT_VERSION=#{format('0x%08x', oci_client_version)}"

if with_config('runtime-check')
  $defs << "-DRUNTIME_API_CHECK=1"
  $libs = saved_libs
end

$objs = ["oci8lib.o", "env.o", "error.o", "oci8.o",
         "stmt.o", "bind.o", "metadata.o", "attr.o",
         "lob.o", "oradate.o",
         "ocinumber.o", "ocidatetime.o", "object.o", "apiwrap.o",
         "encoding.o", "xmldb.o"]

if RUBY_PLATFORM =~ /mswin32|cygwin|mingw32|bccwin32/
  $defs << "-DUSE_WIN32_C"
  $objs << "win32.o"
end

# Checking gcc or not
if oraconf.cc_is_gcc
  $CFLAGS += " -Wall"
end

have_func("localtime_r")

# ruby 1.8 headers
have_header("intern.h")
have_header("util.h")
# ruby 1.9 headers
have_type('rb_encoding', ['ruby/ruby.h', 'ruby/encoding.h'])

# $! in C API
have_var("ruby_errinfo", "ruby.h") # ruby 1.8
have_func("rb_errinfo", "ruby.h")  # ruby 1.9

# replace files
replace = {
  'OCI8_CLIENT_VERSION' => oraconf.version,
  'OCI8_MODULE_VERSION' => RUBY_OCI8_VERSION
}

# make ruby script before running create_makefile.
replace_keyword(File.dirname(__FILE__) + '/../../lib/oci8.rb.in', '../../lib/oci8.rb', replace)

case RUBY_VERSION
when /^1\.9\.1/
  so_basename = "oci8lib_191"
when /^1\.8/
  so_basename = "oci8lib_18"
else
  raise 'unsupported ruby version: ' + RUBY_VERSION
end
$defs << "-DInit_oci8lib=Init_#{so_basename}"

create_header()

# make dependency file
open("depend", "w") do |f|
  extconf_opt = ''
  ['oracle-version', 'runtime-check'].each do |arg|
    opt = with_config(arg)
    case opt
    when String
      extconf_opt += " --with-#{arg}=#{opt}"
    when true
      extconf_opt += " --with-#{arg}=yes"
    when false
      extconf_opt += " --with-#{arg}=no"
    end
  end
  f.puts("Makefile: $(srcdir)/extconf.rb $(srcdir)/oraconf.rb")
  f.puts("\t$(RUBY) $(srcdir)/extconf.rb#{extconf_opt}")
  $objs.each do |obj|
    f.puts("#{obj}: $(srcdir)/#{obj.sub(/\.o$/, ".c")} $(srcdir)/oci8.h apiwrap.h Makefile")
  end
  f.puts("apiwrap.c apiwrap.h: $(srcdir)/apiwrap.c.tmpl $(srcdir)/apiwrap.h.tmpl $(srcdir)/apiwrap.yml $(srcdir)/apiwrap.rb")
  f.puts("\t$(RUBY) $(srcdir)/apiwrap.rb")
end

create_apiwrap()

create_makefile(so_basename)

exit 0
