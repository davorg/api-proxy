package APIProxy;
use Dancer2;
use LWP::UserAgent;

our $VERSION = '0.1';

get '/' => sub {
  template 'index' => { 'title' => 'APIProxy' };
};

get '/gmap_search' => sub {
  my $query = query_parameters->get('q');
  return status_bad_request("Missing 'q' parameter") unless $query;

  my $api_key = $ENV{'GOOGLE_MAPS_API_KEY'};
  return status_bad_request("Missing API key") unless $api_key;

  my $url = "https://www.google.com/maps/embed/v1/search?key=$api_key&q=$query";
  my $ua = LWP::UserAgent->new;
  my $response = $ua->get($url);

  if ($response->is_success) {
    content_type 'text/html';
    return $response->decoded_content;
  } else {
    return status_bad_request("Failed to fetch data from Google Maps API");
  }
};

sub status_bad_request {
  my ($message) = @_;
  status 'bad_request';
  return { error => $message };
}

true;
