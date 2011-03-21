package Slim::Web::JSONRPC;

# $Id: JSONRPC.pm 18535 2008-04-07 23:11:49Z andy $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

# This class provides a JSON-RPC 1.0 API over HTTP to the Slim::Control::Request
# mechanism (sometimes referred to as CLI)

use strict;

use HTTP::Status;
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);

use Slim::Web::HTTP;
use Slim::Utils::Log;


my $log = logger('network.jsonrpc');

# this holds a context for each connection, to enable asynchronous commands as well
# as subscriptions.
our %contexts = ();

# this array provides a function for each supported JSON method
my %methods = (
	'slim.request'        => \&requestMethod,
);


# init
# initializes the JSON RPC code
sub init {

	# register our URI handler
	Slim::Web::HTTP::addRawFunction('jsonrpc.js', \&handleURI);
	
	# register our close handler
	# we want to be called if a connection closes to clear our context
	Slim::Web::HTTP::addCloseHandler(\&handleClose);
}


# handleClose
# deletes any internal references to the $httpClient
sub handleClose {
	my $httpClient = shift || return;

	if (defined $contexts{$httpClient}) {
		$log->debug("Closing any subscriptions for $httpClient");
	
		# remove any subscription management
		Slim::Control::Request::unregisterAutoExecute($httpClient);
		
		# delete the context
		delete $contexts{$httpClient};
	}
}


# handleURI ($httpClient, $httpResponse)
# This is the callback from the HTTP code if the URI of the request matches the
# one we've registered. We're passed the HTTP client object and a HTTP response
# object.
# Decode the request as JSON-RPC 1.0.
sub handleURI {
	my ($httpClient, $httpResponse) = @_;

	$log->debug("handleURI($httpClient)");
	
	# make sure we're connected
	if (!$httpClient->connected()) {
		$log->warn("Aborting, client not connected: $httpClient");
		return;
	}
	
	# cancel any previous subscription on this connection
	# we must have a context defined and a subscription defined
	if (defined($contexts{$httpClient}) && 
		Slim::Control::Request::unregisterAutoExecute($httpClient)) {
	
		# we want to send a last chunk to close the connection as per HTTP...
		# a subscription is essentially a never ending response: we're receiving here
		# a new request (aka pipelining) so we want to be nice and close the previous response
		
		# we cannot have a subscription if this is not a long lasting, keep-open, chunked connection.
		
		Slim::Web::HTTP::addHTTPLastChunk($httpClient, 0);
	}
	
	# get the request data (POST for JSON 1.0)
	my $input = $httpResponse->request()->content();
	
	if (!$input) {

		# No data
		# JSON 1.0 => close connection
		$log->warn("No POST data found => closing connection");

		Slim::Web::HTTP::closeHTTPSocket($httpClient);
		return;
	}

	$log->info("POST data: [$input]");

	# Parse the input
	# Convert JSON to Perl
	# FIXME: JSON 1.0 accepts multiple requests ? How do we parse that efficiently?
	my $procedure = from_json($input);
	
	
	# Validate the procedure
	# We must get a JSON object, i.e. a hash
	if (ref($procedure) ne 'HASH') {
		
		$log->warn("Cannot parse POST data into Perl hash => closing connection");
		
		Slim::Web::HTTP::closeHTTPSocket($httpClient);
		return;
	}
	
	if ( $log->is_debug ) {
		$log->debug( "JSON parsed procedure: " . Data::Dump::dump($procedure) );
	}
	
	# we must have a method
	my $method = $procedure->{'method'};

	if (!$method) {

		$log->warn("Request has no method => closing connection");

		Slim::Web::HTTP::closeHTTPSocket($httpClient);
		return;
	}
	

	# figure out the method wanted
	my $funcPtr = $methods{$method};
	
	if (!$funcPtr) {

		# return error, not a known procedure
		$log->warn("Unknown method $method => closing connection");
		
		Slim::Web::HTTP::closeHTTPSocket($httpClient);
		return;
		
	} elsif (ref($funcPtr) ne 'CODE') {

		# return internal server error
		$log->error("Procedure $method refers to non CODE ??? => closing connection");
		
		Slim::Web::HTTP::closeHTTPSocket($httpClient);
		return;
	}
	

	# parse the parameters
	my $params = $procedure->{'params'};

	if (ref($params) ne 'ARRAY') {
		
		# error, params is an array or an object
		$log->warn("Procedure $method has params not ARRAY => closing connection");
		Slim::Web::HTTP::closeHTTPSocket($httpClient);
		return;
	}
	
	
	# create a hash to store our context
	my $context = {};
	$context->{'httpClient'} = $httpClient;
	$context->{'httpResponse'} = $httpResponse;
	$context->{'procedure'} = $procedure;
	
	
	# Check our operational mode using our X-Jive header
	# We must be delaing with a 1.1 client because X-Jive uses chunked transfers
	# We must not be closing the connection
	if (defined(my $xjive = $httpResponse->request()->header('X-Jive')) &&
		$httpClient->proto_ge('1.1') &&
		$httpResponse->header('Connection') !~ /close/i) {
	
		$log->info("Operating in x-jive mode for procedure $method and client $httpClient");
		$context->{'x-jive'} = 1;
		$httpResponse->header('X-Jive' => 'Jive')
	}
		
	# remember we need to send headers. We'll reset this once sent.
	$context->{'sendheaders'} = 1;
	
	# store our context. It'll get erased by the callback in HTTP.pm through handleClose
	$contexts{$httpClient} = $context;

	# jump to the code handling desired method. It is responsible to send a suitable output
	eval { &{$funcPtr}($context); };

	if ($@) {
		my $funcName = Slim::Utils::PerlRunTime::realNameForCodeRef($funcPtr);
		if ( $log->is_error ) {
			$log->error("While trying to run function coderef [$funcName]: [$@]");
			$log->error( "JSON parsed procedure: " . Data::Dump::dump($procedure) );
		}
		Slim::Web::HTTP::closeHTTPSocket($httpClient);
		return;
	}
}


# writeResponse()
# Writes an JSON RPC response to the httpClient
sub writeResponse {
	my $context = shift;
	my $responseRef = shift;
	
	my $httpClient   = $context->{'httpClient'};
	my $httpResponse = $context->{'httpResponse'};

	if ( $log->is_debug ) {
		$log->debug( "JSON response: " . Data::Dump::dump($responseRef) );
	}
	
	# Don't waste CPU cycles if we're not connected
	if (!$httpClient->connected()) {
		$log->warn("Client disconnected in writeResponse!");
		return;
	}

	# convert Perl object into JSON
	my $jsonResponse = to_json($responseRef);

	$log->info("JSON raw response: [$jsonResponse]");

	$httpResponse->code(RC_OK);
	
	# set a content type to 1.1 proposed value. Should work with 1.0 as it is not specified
	$httpResponse->content_type('application/json');
	
	use bytes;
	
	# send the headers only once
	my $sendheaders = $context->{'sendheaders'};
	if ($sendheaders) {
		$context->{'sendheaders'} = 0;
	}
	
	# in xjive mode, use chunked mode without a last chunk (i.e. we always have $more)
	my $xjive = $context->{'x-jive'};
	
	if ($xjive) {
		$httpResponse->header('Transfer-Encoding' => 'chunked');
	} else {
		$httpResponse->content_length(length($jsonResponse));
	}
	
	if ($sendheaders) {
	
		if ( $log->is_debug ) {
			$log->debug("Response headers: [\n" . $httpResponse->as_string . "]");
		}
	}

	Slim::Web::HTTP::addHTTPResponse($httpClient, $httpResponse, \$jsonResponse, $sendheaders, $xjive);
}


# genreateJSONResponse

sub generateJSONResponse {
	my $context = shift;
	my $result = shift;

	$log->debug("generateJSONResponse()");

	# create an object for the response
	my $response = {};
	
	# add ID if we have it
	if (defined(my $id = $context->{'procedure'}->{'id'})) {
		$response->{'id'} = $id;
	}
	
	# add result
	$response->{'result'} = $result;
	
	# while not strictly allowed, the JSON specs does not forbid to add the
	# request data to the response...
	$response->{'params'} = $context->{'procedure'}->{'params'};
	$response->{'method'} = $context->{'procedure'}->{'method'};

	writeResponse($context, $response);
}


# requestMethod
# Handles 'slim.request' calls. Creates a request object and executes it.
sub requestMethod {
	my $context = shift;

	# get the JSON-RPC params
	my $reqParams = $context->{'procedure'}->{'params'};

	if ( $log->is_debug ) {
		$log->debug( "requestMethod(" . Data::Dump::dump($reqParams) . ")" );
	}
	
	# current style : [<player>, [cmd]]
	# proposed style: [{player:xxx, cmd:[xxx], params:{xxx}}]
	# benefit: more than one command in single request
	# HOW DOES RECEIVER PARSE???
	
	my $commandargs = $reqParams->[1];

	if (!$commandargs || ref($commandargs) ne 'ARRAY') {

		$log->error("commandargs undef or not an array!");
		Slim::Web::HTTP::closeHTTPSocket($context->{'httpClient'});
		return;
	}

	my $playername = scalar ($reqParams->[0]);
	my $client     = Slim::Player::Client::getClient($playername);
	my $clientid = blessed($client) ? $client->id() : undef;
	
	if ($clientid) {

		$log->info("Parsing command: Found client [$clientid]");
	}

	# create a request
	my $request = Slim::Control::Request->new($clientid, $commandargs);

	if ($request->isStatusDispatchable) {
		
		# fix the encoding and/or manage charset param
		$request->fixEncoding();

		# remember we're the source and the $httpClient
		$request->source('JSONRPC');
		$request->connectionID($context->{'httpClient'});
		
		if ($context->{'x-jive'}) {
			# set this in case the query can be subscribed to
			$request->autoExecuteCallback(\&requestWrite);
		}	
		
		$log->info("Dispatching...");

		$request->execute();
		
		if ($request->isStatusError()) {

			if ( $log->is_error ) {
				$log->error("Request failed with error: " . $request->getStatusText);
			}
			
			Slim::Web::HTTP::closeHTTPSocket($context->{'httpClient'});
			return;

 		} else {
 		
 			# handle async commands
 			if ($request->isStatusProcessing()) {
 				
 				$log->info("Request is async: will be back");
 						
 				# add our write routine as a callback
 				$request->callbackParameters(\&requestWrite);
 				return;
			}
			
			# the request was successful and is not async, send results back to caller!
			requestWrite($request, $context->{'httpClient'}, $context);
		}
		
	} else {

		$log->error("request not dispatchable!");
		Slim::Web::HTTP::closeHTTPSocket($context->{'httpClient'});
		return;
	}	
}


# requestWrite( $request $httpClient, $context)
# Writes a request downstream. $httpClient and $context are retrieved if not
# provided (from the request->connectionID and from the contexts array, respectively)
sub requestWrite {
	my $request = shift;
	my $httpClient = shift;
	my $context = shift;

	$log->debug("requestWrite()");
	
	if (!$httpClient) {
		
		# recover our http client
		$httpClient = $request->connectionID();
	}
	
	if (!$context) {
	
		# recover our beloved context
		$context = $contexts{$httpClient};
		
		if (!$context) {
			$log->error("Context not found in requestWrite!!!!");
			return;
		}
	} else {

		if (!$httpClient) {
			$log->error("httpClient not found in requestWrite!!!!");
			return;
		}
	}

	# this should never happen, we've normally been forwarned by the closeHandler
	if (!$httpClient->connected()) {
		$log->info("Client no longer connected in requestWrite");
		handleClose($httpClient);
		return;
	}

	generateJSONResponse($context, $request->{'_results'});
}


1;
