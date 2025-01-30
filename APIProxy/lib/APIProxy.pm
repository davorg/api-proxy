package APIProxy;
use Dancer2;

our $VERSION = '0.1';

get '/' => sub {
  template 'index' => { 'title' => 'APIProxy' };
};

get '/api/:api' => sub {
  my $api = route_parameters->get('api');

  warn "$api\n";

  template 'index' => { 'title' => 'APIProxy' };
};

get '/api/:api/**' => sub {
  my $api = route_parameters->get('api');

  my $rest = splat;

  warn "$api -> $rest\n";

  template 'index' => { 'title' => 'APIProxy' };
};

true;
