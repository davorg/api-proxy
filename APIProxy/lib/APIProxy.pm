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

our $VERSION = '2.0.0';

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
      return upstream_response(
        $cached_response->{status},
        $cached_response->{content},
        $cached_response->{headers},
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

  # Preserve the upstream representation when possible. If decoding fails,
  # use the original content and retain its content-encoding metadata.
  my $content = $response->content;
  my $content_decoded = 0;
  if ($response->header('Content-Encoding')) {
    try {
      my $decoded_content = $response->decoded_content(raise_error => 1);
      if (defined $decoded_content) {
        $content = $decoded_content;
        $content_decoded = 1;
      }
    } catch {
      # The original body and encoding headers remain available as a fallback.
    };
  }

  my $headers = upstream_headers($response, $content_decoded);

  # Cache complete successful responses. Keep the existing policy of fetching
  # upstream errors again rather than caching a transient failure.
  if ($api->{cache} && $response->is_success) {
    cache->set($cache_key, {
      status  => $response->code,
      content => $content,
      headers => $headers,
    }, $CACHE_TTL);
  }

  my $duration = time() - $start_time;
  my $log_status = $response->is_success
    ? 'success'
    : 'upstream_' . $response->code;
  log_request($api_name, $params, $log_status, $duration);

  return upstream_response($response->code, $content, $headers);
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

sub upstream_headers {
  my ($response, $decoded) = @_;

  my %excluded = map { $_ => 1 } qw(
    connection keep-alive proxy-authenticate proxy-authorization proxy-connection
    te trailer transfer-encoding upgrade
  );
  if ($decoded) {
    $excluded{$_} = 1
      for qw(content-encoding content-length content-md5 digest content-digest repr-digest);
  }

  my $connection = $response->header('Connection') // '';
  $excluded{lc $_} = 1 for grep { length } split /\s*,\s*/, $connection;

  my @headers;
  $response->headers->scan(sub {
    my ($name, $value) = @_;
    return if $excluded{lc $name};
    push @headers, [ $name, $value ];
  });

  return \@headers;
}

sub upstream_response {
  my ($upstream_status, $content, $headers) = @_;
  status $upstream_status;

  my %seen_headers;
  for my $header (@{ $headers || [] }) {
    my ($name, $value) = @$header;
    my $normalized_name = lc $name;
    if ($seen_headers{$normalized_name}++) {
      push_response_header $name => $value;
    } else {
      response_header $name => $value;
    }
  }
  response_header 'Access-Control-Allow-Origin' => '*'
    unless $seen_headers{'access-control-allow-origin'};

  return $content;
}

true;
