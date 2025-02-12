package APIProxy;
use Dancer2;
use LWP::UserAgent;

our $VERSION = '0.1';

get '/' => sub {
  template 'index' => { 'title' => 'APIProxy' };
};

my %apis = (
  gmap_search => {
    params => [ 'q' ],
    url    => 'https://www.google.com/maps/embed/v1/search?key=KEY_HERE',
    key    => 'GOOGLE_MAPS_API_KEY',
  },
);

get '/:api' => sub {
  my $api_name = route_parameters->get('api');
  my $api = $apis{$api_name};

  return 404 unless $api;

  my $params;
  for (@{ $api->{params} }) {
    $params->{$_} = query_parameters->get($_);
    return status_bad_request("Missing '$_' parameter") unless $params->{$_};
    $params->{$_} =~ s/ +/+/g;
  }

  my $api_key = $ENV{$api->{key}};
  return status_bad_request("Missing API key") unless $api_key;

  my $url = $api->{url};

  $url =~ s/KEY_HERE/$api_key/;

  if (keys %$params) {
    $url .= '&';

    $url .= join '&', map { "$_=$params->{$_}" } keys %$params;
  }

  my $referrer = request->header('Referer');

  my $ua = LWP::UserAgent->new;

  $ua->default_header('Referer' => $referrer);  # Forward dynamically
  $ua->default_header('User-Agent' => 'Mozilla/5.0');   # Avoid bot detection


  warn $url, "\n";
  my $response = $ua->get($url);

  if ($response->is_redirect) {
    my $redirect_url = $response->header('Location');
    warn $redirect_url, "\n";
    $response = $ua->get($redirect_url);
  }

  #if ($response->is_success) {
    content_type $response->header('Content-Type');
    response_header 'Access-Control-Allow-Origin' => '*';
    return $response->content;
  #} else {
  #  return status_bad_request("Failed to fetch data from Google Maps API");
  #}
};

sub status_bad_request {
  my ($message) = @_;
  warn "$message\n";
  status 'bad_request';
  return { error => $message };
}

true;
