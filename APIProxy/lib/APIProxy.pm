package APIProxy;
use Dancer2;
use LWP::UserAgent;
use Dancer2::Plugin::Cache::CHI;
use Time::HiRes qw(time);
use JSON::MaybeXS;
use Try::Tiny;

our $VERSION = '0.1';

# Configuration
my $CACHE_TTL = 300;  # 5 minutes
my $REQUEST_TIMEOUT = 30;  # seconds

# Initialize caching
plugin 'Cache::CHI' => {
  driver => 'File',
  root_dir => '/tmp/api_proxy_cache',
};

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

  warn encode_json($log_entry) . "\n";
}

get '/' => sub {
  template 'index' => { 'title' => 'APIProxy' };
};

get '/:api' => sub {
  my $api_name = route_parameters->get('api');
  my $api = $apis{$api_name};

  return status_not_found("API '$api_name' not found") unless $api;

  # Start timing the request
  my $start_time = time();

  # Validate and sanitize parameters
  my $params;
  for (@{ $api->{params} }) {
    my $value = query_parameters->get($_);
    return status_bad_request("Missing '$_' parameter") unless $value;

    # Sanitize input
    $value =~ s/[^\w\s\-.,]/ /g;  # Remove special characters
    $value =~ s/ +/+/g;           # Replace spaces with +
    $params->{$_} = $value;
  }

  # Check API key
  my $api_key = $ENV{$api->{key}};
  return status_bad_request("Missing API key") unless $api_key;

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
    agent   => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  );

  # Forward headers
  my $referrer = request->header('Referer');
  $ua->default_header('Referer' => $referrer) if $referrer;

  # Add browser-like headers
  $ua->default_header(
    'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
    'Accept-Language' => 'en-US,en;q=0.9',
    'Accept-Encoding' => 'gzip, deflate, br',
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
  try {
    $response = $ua->get($url);
  } catch {
    my $duration = time() - $start_time;
    log_request($api_name, $params, 'error', $duration);
    return status_internal_error("Failed to connect to API: $_");
  };

  # Handle redirects
  while ($response->is_redirect) {
    my $redirect_url = $response->header('Location');
    try {
      $response = $ua->get($redirect_url);
    } catch {
      my $duration = time() - $start_time;
      log_request($api_name, $params, 'redirect_error', $duration);
      return status_internal_error("Failed to follow redirect: $_");
    };
  }

  # Handle response
  if ($response->is_success) {
    my $content = $response->content;
        
    # Cache successful responses if enabled
    if ($api->{cache}) {
      my $cache_key = join(':', $api_name, map { "$_=$params->{$_}" } sort keys %$params);
      cache->set($cache_key, $content, $CACHE_TTL);
    }

    my $duration = time() - $start_time;
    log_request($api_name, $params, 'success', $duration);

    content_type $response->header('Content-Type');
    response_header 'Access-Control-Allow-Origin' => '*';
    return $content;
  } else {
    my $duration = time() - $start_time;
    log_request($api_name, $params, 'error', $duration);
    return status_bad_request("API request failed: " . $response->status_line);
  }
};

sub status_bad_request {
  my ($message) = @_;
  status 'bad_request';
  return { error => $message };
}

sub status_not_found {
  my ($message) = @_;
  status 'not_found';
  return { error => $message };
}

sub status_internal_error {
  my ($message) = @_;
  status 'internal_server_error';
  return { error => $message };
}

true;
