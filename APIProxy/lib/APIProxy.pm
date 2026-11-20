package APIProxy;
use Dancer2;
use LWP::UserAgent;
use HTTP::Message ();
use URI;
use URI::Escape qw(uri_escape_utf8);
use Dancer2::Plugin::Cache::CHI;
use File::Basename qw(dirname);
use File::Spec;
use Time::HiRes qw(time);
use Try::Tiny;
use YAML ();

our $VERSION = '1.0.1';

# Configuration
my $CACHE_TTL = 300;  # 5 minutes
my $REQUEST_TIMEOUT = 30;  # seconds
my $MAX_REDIRECTS = 5;

# Load API definitions from a configurable file. The checked-in file keeps the
# current service usable by default, while deployments can provide their own.
my $api_config_file = $ENV{APIPROXY_APIS_FILE}
  || File::Spec->catfile(dirname(__FILE__), '..', 'apis.yml');
my $apis = YAML::LoadFile($api_config_file);
die "API configuration '$api_config_file' must contain a mapping\n"
  unless ref($apis) eq 'HASH';
for my $api_name (sort keys %$apis) {
  my $api = $apis->{$api_name};
  die "API configuration '$api_config_file': '$api_name' must be a mapping\n"
    unless ref($api) eq 'HASH';
  die "API configuration '$api_config_file': '$api_name' needs a URL and key name\n"
    unless defined $api->{url} && defined $api->{key};
  die "API configuration '$api_config_file': '$api_name' params must be a list\n"
    unless ref($api->{params}) eq 'ARRAY';
}

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
  template 'index' => {
    title          => 'API Proxy',
    version        => $VERSION,
    supported_apis => [ sort keys %$apis ],
  };
};

my $api_route = sub {
  my $api_name = route_parameters->get('api');
  my $api = $apis->{$api_name};

  return error_response(404, "API '$api_name' not found") unless $api;

  # Start timing the request
  my $start_time = time();

  # Validate required parameters without changing the caller's search terms.
  my $params = {};
  for my $param (@{ $api->{params} }) {
    my $value = query_parameters->get($param);
    return error_response(400, "Missing '$param' parameter")
      unless defined $value && $value =~ /\S/;
    $params->{$param} = $value;
  }

  # Check API key
  my $api_key = $ENV{$api->{key}};
  return error_response(500, 'Server API key is not configured') unless $api_key;

  my $cache_key;

  # Check cache if enabled
  if ($api->{cache}) {
    $cache_key = join(':', uri_escape_utf8($api_name), map {
      uri_escape_utf8($_) . '=' . uri_escape_utf8($params->{$_})
    } sort keys %$params);
    my $cached_response = cache->get($cache_key);
    if (defined $cached_response) {
      my $duration = time() - $start_time;
      log_request($api_name, $params, 'cached', $duration);
      return success_response(
        $cached_response->{content},
        $cached_response->{content_type},
      );
    }
  }

  # Construct URL and encode each query component independently so values
  # cannot add parameters and Unicode is sent as UTF-8.
  my $url = $api->{url};
  $url =~ s/KEY_HERE/uri_escape_utf8($api_key)/ge;
  my $uri = URI->new($url);
  my $query = $uri->query // '';
  my @query_params = map {
    uri_escape_utf8($_) . '=' . uri_escape_utf8($params->{$_})
  } sort keys %$params;
  if (@query_params) {
    $query .= '&' if length $query;
    $query .= join '&', @query_params;
  }
  $uri->query($query);
  $url = $uri->as_string;

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
        
    my $upstream_content_type = $response->header('Content-Type');

    # Cache the body and metadata together. The entry itself marks a hit, even
    # when the successful response body is empty.
    if ($api->{cache}) {
      cache->set($cache_key, {
        content      => $content,
        content_type => $upstream_content_type,
      }, $CACHE_TTL);
    }

    my $duration = time() - $start_time;
    log_request($api_name, $params, 'success', $duration);

    return success_response($content, $upstream_content_type);
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

get '/:api'  => $api_route;
get '/:api/' => $api_route;

sub error_response {
  my ($code, $message) = @_;
  status $code;
  content_type 'application/json';
  response_header 'Access-Control-Allow-Origin' => '*';
  return to_json({ error => $message });
}

sub success_response {
  my ($content, $upstream_content_type) = @_;
  content_type $upstream_content_type if defined $upstream_content_type;
  response_header 'Access-Control-Allow-Origin' => '*';
  return $content;
}

true;
