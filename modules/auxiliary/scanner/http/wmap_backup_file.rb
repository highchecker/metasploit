##
# $Id: backupfile.rb 1000 2008-25-02 08:21:36Z et $
##

##
# This file is part of the Metasploit Framework and may be subject to 
# redistribution and commercial restrictions. Please see the Metasploit
# Framework web site for more information on licensing and terms of use.
# http://metasploit.com/projects/Framework/
##

require 'rex/proto/http'
require 'msf/core'

module Msf


class Auxiliary::Scanner::Http::Wmap_Backup_File < Msf::Auxiliary

	include Exploit::Remote::HttpClient
	include Auxiliary::WMAPScanFile
	include Auxiliary::Scanner

	def initialize(info = {})
		super(update_info(info,	
			'Name'   		=> 'HTTP Backup File Scanner',
			'Description'	=> %q{
				This module identifies the existence of possible copies 
				of a especific file in a given path.
			},
			'Author' 		=> [ 'et [at] cyberspace.org' ],
			'License'		=> BSD_LICENSE,
			'Version'		=> '$Revision: 1000 $'))   
			
		register_options(
			[
				OptString.new('PATH', [ true,  "The path/file to identify backups", '/index.asp'])
			], self.class)	
							
	end

	def run_host(ip)
	
		bakextensions = [
						'bak',
						'backup',
						'txt', 
						'old', 
						'copy',
						'temp'
						]

		bakextensions.each do |ext|
				begin
				res = send_request_cgi({
					'uri'  		=>  datastore['PATH']+"."+ext,
					'method'   	=> 'GET',
					'ctype'		=> 'text/plain'
					}, 20)

				if (res and res.code >= 200 and res.code < 300) 
				 	print_status("Found http://#{target_host}:#{datastore['RPORT']}#{datastore['PATH']}.#{ext}")
				else
				   	print_status("NOT Found http://#{target_host}:#{datastore['RPORT']}#{datastore['PATH']}.#{ext}") 
					#To be removed or just displayed with verbose debugging.
				end

			rescue ::Rex::ConnectionRefused, ::Rex::HostUnreachable, ::Rex::ConnectionTimeout
			rescue ::Timeout::Error, ::Errno::EPIPE			
			end
	
		end
	
	end

end
end	
