module Msf

###
#
# This module provides methods for brute forcing authentication
#
###

module Auxiliary::AuthBrute

	def initialize(info = {})
		super

		register_options([
			OptString.new('USERNAME', [ false, 'A specific username to authenticate as' ]),
			OptString.new('PASSWORD', [ false, 'A specific password to authenticate with' ]),
			OptPath.new('USER_FILE', [ false, "File containing usernames, one per line" ]),
			OptPath.new('PASS_FILE', [ false, "File containing passwords, one per line" ]),
			OptPath.new('USERPASS_FILE',  [ false, "File containing users and passwords separated by space, one pair per line" ]),
			OptInt.new('BRUTEFORCE_SPEED', [ true, "How fast to bruteforce, from 0 to 5", 5]),
			OptBool.new('VERBOSE', [ true, "Whether to print output for all attempts", true]),
			OptBool.new('BLANK_PASSWORDS', [ false, "Try blank passwords for all users", true]),
			OptBool.new('USER_AS_PASS', [ false, "Try the username as the password for all users", true]),
			OptBool.new('STOP_ON_SUCCESS', [ true, "Stop guessing when a credential works for a host", false]),
		], Auxiliary::AuthBrute)

		register_advanced_options([
			OptBool.new('REMOVE_USER_FILE', [ true, "Automatically delete the USER_FILE on module completion", false]),
			OptBool.new('REMOVE_PASS_FILE', [ true, "Automatically delete the PASS_FILE on module completion", false]),
			OptBool.new('REMOVE_USERPASS_FILE', [ true, "Automatically delete the USERPASS_FILE on module completion", false]),
			OptInt.new('MaxGuessesPerService', [ false, "Maximum number of credentials to try per service instance.", 0])
		], Auxiliary::AuthBrute)

	end

	# Checks all three files for usernames and passwords, and combines them into
	# one credential list to apply against the supplied block. The block (usually
	# something like do_login(user,pass) ) is responsible for actually recording
	# success and failure in its own way; each_user_pass() will only respond to
	# a return value of :done (which will signal to end all processing) and
	# to :next_user (which will cause that username to be skipped for subsequent
	# password guesses). Other return values won't affect the processing of the
	# list.
	#
	# The 'noconn' argument should be set to true if each_user_pass is merely
	# iterating over the usernames and passwords and should not respect 
	# bruteforce_speed as a delaying factor.
	def each_user_pass(noconn=false,&block)
		this_service = [datastore['RHOST'],datastore['RPORT']].join(":")
		fq_rest = [this_service,"all remaining users"].join(":")

		credentials = build_credentials_array()
		initialize_class_variables(credentials)

		credentials.each do |u, p|
			# Explicitly be able to set a blank (zero-byte) username by setting the
			# username to <BLANK>. It's up to the caller to handle this if it's not
			# allowed or if there's any special handling needed (such as smb_login).
			u = "" if u =~ /^<BLANK>$/i
			break if @@credentials_skipped[fq_rest]

			fq_user = [this_service,u].join(":")

			# Set noconn to indicate that in this case, each_user_pass
			# is not actually kicking off a connection, so the
			# bruteforce_speed datastore should be ignored.
			if not noconn
				userpass_sleep_interval unless @@credentials_tried.empty?
			end

			next if @@credentials_skipped[fq_user]
			next if @@credentials_tried[fq_user] == p

			ret = block.call(u, p)

			case ret
			when :abort # Skip the current host entirely.
				break

			when :next_user # This means success for that user.
				@@credentials_skipped[fq_user] = p
				if datastore['STOP_ON_SUCCESS'] # See?
					@@credentials_skipped[fq_rest] = true
				end

			when :skip_user # Skip the user in non-success cases. 
				@@credentials_skipped[fq_user] = p

			when :connection_error # Report an error, skip this cred, but don't abort.
				print_brute(
					:level => :verror, 
					:ip => datastore['RHOST'],
					:port => datastore['RPORT'],
					:msg => "Connection error, skipping '#{u}':'#{p}'")
			end

			@@guesses_per_service[this_service] ||= 1
			@@credentials_tried[fq_user] = p

			if @@guesses_per_service[this_service] >= (@@max_per_service)
				if @@max_per_service < credentials.size
					print_brute(
						:level => :vstatus,
						:ip => datastore['RHOST'],
						:port => datastore['RPORT'],
						:msg => "Hit maximum guesses for this service.")
					break
				end
			else
				@@guesses_per_service[this_service] += 1
			end
		end
	end

	def unset_attempt_counters(ip,port)
		@@guesses_per_service ||= {}
		@@guesses_per_service["#{ip}:#{port}"] = nil 
		@@max_per_service = nil 
	end

	def build_credentials_array
		credentials = extract_word_pair(datastore['USERPASS_FILE'])

		translate_proto_datastores()

		users = load_user_vars(credentials)
		passwords = load_password_vars(credentials)

		cleanup_files()

		if datastore['USER_AS_PASS']
			credentials = gen_user_as_password(users, credentials)
		end

		if datastore['BLANK_PASSWORDS']
			credentials = gen_blank_passwords(users, credentials)
		end

		credentials.concat(combine_users_and_passwords(users, passwords))
		credentials.uniq!
		credentials = just_uniq_passwords(credentials) if @strip_usernames
		return credentials
	end

	# Class variables to track credential use. They need
	# to be class variables due to threading. 
	def initialize_class_variables(credentials)
		@@credentials_skipped = {}
		@@credentials_tried   = {}
		@@guesses_per_service = {}

		if datastore['MaxGuessesPerService'].to_i == 0 
			@@max_per_service = credentials.size
		else
			if datastore['MaxGuessesPerService'].to_i >= credentials.size
				@@max_per_service = credentials.size
				print_brute(
					:level => :vstatus,
					:ip => datastore['RHOST'],
					:port => datastore['RPORT'],
					:msg => "Adjusting MaxGuessesPerService to the actual total number of credentials")
			else
				@@max_per_service = datastore['MaxGuessesPerService'].to_i
			end
		end
	end

	def load_user_vars(credentials = nil)
		users = extract_words(datastore['USER_FILE'])
		if datastore['USERNAME']
			users.unshift datastore['USERNAME']
			credentials = prepend_chosen_username(datastore['USERNAME'], credentials) if credentials
		end
		users
	end

	def load_password_vars(credentials = nil)
		passwords = extract_words(datastore['PASS_FILE'])
		if datastore['PASSWORD']
			passwords.unshift datastore['PASSWORD']
			credentials = prepend_chosen_password(datastore['PASSWORD'], credentials) if credentials
		end
		passwords
	end


	# Takes protocol-specific username and password fields, and,
	# if present, prefer those over any given USERNAME or PASSWORD.
	# Note, these special username/passwords should get deprecated
	# some day. Note2: Don't use with SMB and FTP at the same time!
	def translate_proto_datastores
		switched = false
		['SMBUser','FTPUSER'].each do |u|
			if datastore[u] and !datastore[u].empty?
				datastore['USERNAME'] = datastore[u]
			end
		end
		['SMBPass','FTPPASS'].each do |p|
			if datastore[p] and !datastore[p].empty?
				datastore['PASSWORD'] = datastore[p]
			end
		end
	end

	def just_uniq_passwords(credentials)
		credentials.map{|x| ["",x[1]]}.uniq
	end

	def prepend_chosen_username(user,cred_array)
		cred_array.map {|pair| [user,pair[1]]} + cred_array
	end

	def prepend_chosen_password(pass,cred_array)
		cred_array.map {|pair| [pair[0],pass]} + cred_array
	end

	def gen_blank_passwords(user_array,cred_array)
		blank_passwords = []
		unless user_array.empty?
			blank_passwords.concat(user_array.map {|u| [u,""]})
		end
		unless cred_array.empty?
			cred_array.each {|u,p| blank_passwords << [u,""]}
		end
		return(blank_passwords + cred_array)
	end

	def gen_user_as_password(user_array,cred_array)
		user_as_passwords = []
		unless user_array.empty?
			user_as_passwords.concat(user_array.map {|u| [u,u]})
		end
		unless cred_array.empty?
			cred_array.each {|u,p| user_as_passwords << [u,u]}
		end
		return(user_as_passwords + cred_array)
	end

	def combine_users_and_passwords(user_array,pass_array)
		if (user_array.length + pass_array.length) < 1
			return []
		end
		combined_array = []
		if pass_array.empty?
			combined_array = user_array.map {|u| [u,""] }
		elsif user_array.empty?
			combined_array = pass_array.map {|p| ["",p] }
		else
			user_array.each do |u|
				pass_array.each do |p|
					combined_array << [u,p]
				end
			end
		end

		# Move datastore['USERNAME'] and datastore['PASSWORD'] to the front of the list.
		creds = [ [], [], [], [] ] # userpass, pass, user, rest
		combined_array.each do |pair|
			if pair == [datastore['USERNAME'],datastore['PASSWORD']]
				creds[0] << pair
			elsif pair[1] == datastore['PASSWORD']
				creds[1] << pair
			elsif pair[0] == datastore['USERNAME']
				creds[2] << pair
			else
				creds[3] << pair
			end
		end
		return creds[0] + creds[1] + creds[2] + creds[3]
	end

	def extract_words(wordfile)
		return [] unless wordfile && File.readable?(wordfile)
		begin
			words = File.open(wordfile) {|f| f.read(f.stat.size)}
		rescue
			return
		end
		save_array = words.split(/\r?\n/)
		return save_array
	end

	def extract_word_pair(wordfile)
		return [] unless wordfile && File.readable?(wordfile)
		creds = []
		begin
			upfile_contents = File.open(wordfile) {|f| f.read(f.stat.size)}
		rescue
			return []
		end
		upfile_contents.split(/\n/).each do |line|
			user,pass = line.split(/\s+/,2).map { |x| x.strip }
			creds << [user.to_s, pass.to_s]
		end
		return creds
	end

	def userpass_sleep_interval
		sleep_time = case datastore['BRUTEFORCE_SPEED'].to_i
			when 0; 60 * 5
			when 1; 15
			when 2; 1
			when 3; 0.5
			when 4; 0.1
			else; 0
		end
		::IO.select(nil,nil,nil,sleep_time) unless sleep_time == 0
	end

	# Provides a consistant way to display messages about AuthBrute-mixed modules.
	# Acceptable opts are fairly self-explanitory, but :level can be tricky.
	#
	# It can be one of status, good, error, or line (and corresponds to the usual 
	# print_status, print_good, etc. methods).
	#
	# If it's preceded by a "v" (ie, vgood, verror, etc), only print if 
	# datstore["VERBOSE"] is set to true.
	#
	# If :level would make the method nonsense, default to print_status.
	def print_brute(opts={})
		if opts[:level] and opts[:level].to_s[/^v/]
			return unless datastore["VERBOSE"]
			level = opts[:level].to_s[1,16].strip
		else
			level = opts[:level].to_s.strip
		end

		host_ip = opts[:ip] || opts[:rhost] || opts[:host] 
		host_port = opts[:port] || opts[:rport] || (rport rescue nil)
		msg = opts[:msg] || opts[:message]
		proto = opts[:proto] || opts[:protocol] || proto_from_fullname

		complete_message = build_brute_message(host_ip,host_port,proto,msg)

		print_method = "print_#{level}"
		if self.respond_to? print_method
			self.send print_method, complete_message
		else
			print_status complete_message
		end
	end

	# Depending on the non-nil elements, build up a standardized
	# auth_brute message, but support the old style used by
	# vprint_status and friends as well.
	def build_brute_message(host_ip,host_port,proto,msg)
		ip = host_ip.to_s.strip if host_ip
		port = host_port.to_s.strip if host_port
		complete_message = ""
		unless ip && port
			complete_message = msg.to_s.strip
		else
			complete_message << [ip,port].join(":")
			(complete_message << " - ") if ip
			complete_message << "#{proto.to_s.strip} - " if proto
			progress = tried_over_total(ip,port)
			complete_message << progress if progress
			complete_message << msg.to_s.strip
		end
	end

	# Fun trick: Only prints if we're already in each_user_pass, since
	# only then is @@max_per_service defined.
	def tried_over_total(ip,port)
		total = self.class.class_variable_get("@@max_per_service") rescue nil
		return unless total
		total = total.to_i
		current_try = (@@guesses_per_service["#{ip}:#{port}"] || 1).to_i
		pad = total.to_s.size
		"[%0#{pad}d/%0#{pad}d] - " % [current_try, total]
	end

	# Protocols can nearly always be automatically determined from the
	# name of the module, assuming the name is sensible like ssh_login or
	# smb_auth.
	def proto_from_fullname
		File.split(self.fullname).last.match(/^(.*)_(login|auth)/)[1].upcase rescue nil
	end

	# Legacy vprint
	def vprint_status(msg='')
		print_brute :level => :vstatus, :msg => msg
	end

	# Legacy vprint
	def vprint_error(msg='')
		print_brute :level => :verror, :msg => msg
	end

	# Legacy vprint
	def vprint_good(msg='')
		print_brute :level => :vgood, :msg => msg
	end

	# This method deletes the dictionary files if requested
	def cleanup_files
		path = datastore['USERPASS_FILE']
		if path and datastore['REMOVE_USERPASS_FILE']
			::File.unlink(path) rescue nil
		end

		path = datastore['USER_FILE']
		if path and datastore['REMOVE_USER_FILE']
			::File.unlink(path) rescue nil
		end

		path = datastore['PASS_FILE']
		if path and datastore['REMOVE_PASS_FILE']
			::File.unlink(path) rescue nil
		end
	end

end
end

