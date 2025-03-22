requires 'Dancer2' => '0.300000';
requires 'LWP::UserAgent' => '6.67';
requires 'Dancer2::Plugin::Cache::CHI' => '0.0.3';
requires 'Time::HiRes' => '1.9764';
requires 'JSON::MaybeXS' => '1.004005';

# Development dependencies
on 'develop' => sub {
    requires 'Test::More' => '1.302190';
    requires 'Test::Exception' => '0.43';
    requires 'Test::MockObject' => '1.20200102';
}; 