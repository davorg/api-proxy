use strict;
use warnings;

use APIProxy;
use Test::More;
use Plack::Test;
use HTTP::Request::Common;
use HTTP::Response;
use Ref::Util qw<is_coderef>;

local $ENV{GOOGLE_MAPS_API_KEY} = 'test-only-google-maps-key';

# Use the real cache plugin with a private datastore, regardless of host config.
# Production cache configuration is covered separately by issue #5.
APIProxy::set(plugins => {
    'Cache::CHI' => { driver => 'Memory', global => 0 },
});

my $content = '<html><body>Google Maps test fixture</body></html>';
my $fixture = HTTP::Response->new(
    200, 'OK', [ 'Content-Type' => 'text/html' ], $content,
);
my @upstream_urls;

{
    no warnings 'redefine';
    # Guard the transport as well as replacing get: a missed mock must fail
    # locally rather than send a request using a developer's credentials.
    local *LWP::UserAgent::request = sub {
        BAIL_OUT('Network access is disabled in the isolated route test');
    };
    local *LWP::UserAgent::get = sub {
        my ($ua, $url) = @_;
        push @upstream_urls, $url;
        return $fixture->clone;
    };

    my $app = APIProxy->to_app;
    ok( is_coderef($app), 'Got app' );
    my $test = Plack::Test->create($app);

    subtest 'invalid requests do not call upstream' => sub {
        is( $test->request(GET '/unknown_api')->code, 404, 'Unknown API is rejected' );
        is( $test->request(GET '/gmap_search')->code, 400, 'Missing q is rejected' );
        {
            local $ENV{GOOGLE_MAPS_API_KEY};
            ok( !$test->request(GET '/gmap_search?q=Perl')->is_success,
                'Missing server key is rejected' );
        }
        is( scalar @upstream_urls, 0, 'No upstream calls for invalid requests' );
    };

    subtest 'cache miss uses the dummy key and mocked HTML' => sub {
        my $res = $test->request(GET '/gmap_search?q=Perl');
        is( $res->code, 200, 'Request succeeds' );
        is( $res->content_type, 'text/html', 'Upstream media type is returned' );
        is( $res->content, $content, 'Response contains only the fixture HTML' );
        is_deeply( \@upstream_urls, [
            'https://www.google.com/maps/embed/v1/search?key=test-only-google-maps-key&q=Perl',
        ], 'One upstream call with the expected query and dummy key' );
    };

    subtest 'repeat request is served from the private cache' => sub {
        my $res = $test->request(GET '/gmap_search?q=Perl');
        is( $res->code, 200, 'Cached request succeeds' );
        is( $res->content, $content, 'Cache returns the fixture HTML' );
        is( scalar @upstream_urls, 1, 'Cache hit makes no further upstream call' );
    };

    subtest 'clearing the test cache causes a fresh fetch' => sub {
        APIProxy::cache()->clear;
        my $res = $test->request(GET '/gmap_search?q=Perl');
        is( $res->content, $content, 'Fresh fetch returns fixture HTML' );
        is( scalar @upstream_urls, 2, 'Upstream is called again after clearing cache' );
    };
}

done_testing;
