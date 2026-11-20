package APIProxy;
use Dancer2;
use LWP::UserAgent;
use HTTP::Message ();
use Dancer2::Plugin::Cache::CHI;
use Time::HiRes qw(time);
use Try::Tiny;

our $VERSION = '1.0.0';

# Configuration
my $CACHE_TTL = 300;  # 5 minutes
my $REQUEST_TIMEOUT = 30;  # seconds
my $MAX_REDIRECTS = 5;

# API configurations
my %apis = (
  gmap_search => {
    params => [ 'q' ],
    url    => 'https://www.google.com/maps/embed/v1/search?key=KEY_HERE',
    key    => 'GOOGLE_MAPS_API_KEY',
    cache  => 1,
    timeout => 30,
  },
);

# Logging helper
sub log_request {
  my ($api_name, $params, $status, $duration) = @_;
  my $timestamp = time();
  my $log_entry = {
    timestamp => $timestamp,
    api       => $api_name,
    params    => $params,
    status    => $status,
    duration  => $duration,
    ip        => request->remote_address,
  };

  warn to_json($log_entry) . "\n";
}

get '/' => sub {
  template 'index' => { 'title' => 'APIProxy' };
};

get '/:api' => sub {
  my $api_name = route_parameters->get('api');
  my $api = $apis{$api_name};

  return error_response(404, "API '$api_name' not found") unless $api;

  # Start timing the request
  my $start_time = time();

  # Validate and sanitize parameters
  my $params;
  for (@{ $api->{params} }) {
    my $value = query_parameters->get($_);
    return error_response(400, "Missing '$_' parameter") unless $value;

    # Sanitize input
    $value =~ s/[^\w\s\-.,]/ /g;  # Remove special characters
    $value =~ s/ +/+/g;           # Replace spaces with +
    $params->{$_} = $value;
  }

  # Check API key
  my $api_key = $ENV{$api->{key}};
  return error_response(500, 'Server API key is not configured') unless $api_key;

  # Check cache if enabled
  if ($api->{cache}) {
    my $cache_key = join(':', $api_name, map { "$_=$params->{$_}" } sort keys %$params);
    my $cached_response = cache->get($cache_key);
    if ($cached_response) {
      my $duration = time() - $start_time;
      log_request($api_name, $params, 'cached', $duration);
      return $cached_response;
    }
  }

  # Construct URL
  my $url = $api->{url};
  $url =~ s/KEY_HERE/$api_key/;
    
  if (keys %$params) {
    $url .= '&' . join '&', map { "$_=$params->{$_}" } keys %$params;
  }

  # Setup UserAgent
  my $ua = LWP::UserAgent->new(
    timeout => $api->{timeout} || $REQUEST_TIMEOUT,
    max_redirect => $MAX_REDIRECTS,
    agent   => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  );

  # Forward headers
  my $referrer = request->header('Referer');
  $ua->default_header('Referer' => $referrer) if $referrer;

  # Add browser-like headers
  $ua->default_header(
    'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
    'Accept-Language' => 'en-US,en;q=0.9',
    'Accept-Encoding' => HTTP::Message::decodable(),
    'Connection' => 'keep-alive',
    'Sec-Ch-Ua' => '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
    'Sec-Ch-Ua-Mobile' => '?0',
    'Sec-Ch-Ua-Platform' => '"Windows"',
    'Sec-Fetch-Dest' => 'document',
    'Sec-Fetch-Mode' => 'navigate',
    'Sec-Fetch-Site' => 'none',
    'Sec-Fetch-User' => '?1',
    'Upgrade-Insecure-Requests' => '1',
    'Cache-Control' => 'max-age=0',
  );

  # Make request with error handling
  my $response;
  my $request_error;
  try {
    $response = $ua->get($url);
  } catch {
    my $duration = time() - $start_time;
    log_request($api_name, $params, 'error', $duration);
    $request_error = $_;
  };

  if (defined $request_error) {
    $request_error =~ s/\Q$api_key\E/[redacted]/g;
    warn "Upstream API request failed: $request_error\n";
    my $timed_out = $request_error =~ /timeout|timed?\s*out/i;
    return error_response(
      $timed_out ? 504 : 502,
      $timed_out ? 'Upstream API request timed out' : 'Failed to connect to upstream API',
    );
  }

  # LWP follows relative and absolute redirects up to this UA's configured
  # limit. A redirect response still present here has exceeded that limit.
  if ($response->is_redirect) {
    my $duration = time() - $start_time;
    log_request($api_name, $params, 'redirect_limit', $duration);
    return error_response(502, 'Upstream API exceeded the redirect limit');
  }

  # Handle response
  if ($response->is_success) {
    my $content;
    my $decode_error;
    try {
      $content = $response->decoded_content(raise_error => 1);
    } catch {
      $decode_error = $_;
    };

    unless (defined $content) {
      my $duration = time() - $start_time;
      log_request($api_name, $params, 'decode_error', $duration);
      warn "Failed to decode upstream response: $decode_error\n";
      return error_response(502, 'Upstream API returned unsupported or invalid content encoding');
    }
        
    # Cache successful responses if enabled
    if ($api->{cache}) {
      my $cache_key = join(':', $api_name, map { "$_=$params->{$_}" } sort keys %$params);
      cache->set($cache_key, $content, $CACHE_TTL);
    }

    my $duration = time() - $start_time;
    log_request($api_name, $params, 'success', $duration);

    content_type $response->header('Content-Type');
    warn 'Content-Type: ', $response->header('Content-Type'), "\n";
    response_header 'Access-Control-Allow-Origin' => '*';
    return $content;
  } else {
    my $duration = time() - $start_time;
    log_request($api_name, $params, 'error', $duration);
    my $timed_out = $response->code == 408
      || $response->code == 504
      || $response->status_line =~ /timeout|timed?\s*out/i;
    my $status = $timed_out ? 504 : 502;
    my $message = $timed_out
      ? 'Upstream API request timed out'
      : 'Upstream API returned HTTP ' . $response->code;
    return error_response($status, $message);
  }
};

sub error_response {
  my ($code, $message) = @_;
  status $code;
  content_type 'application/json';
  response_header 'Access-Control-Allow-Origin' => '*';
  return to_json({ error => $message });
}

true;
