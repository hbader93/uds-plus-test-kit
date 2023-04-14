require 'inferno/dsl/oauth_credentials'
require 'smart_app_launch_test_kit'
require_relative './version'
require_relative './validate_data'

module UDSPlusTestKit
    class UDSPlusTestSuite < Inferno::TestSuite
        title 'UDS+ Test Kit'
        description %(
            The UDS+ Test Kit tests systems for their conformance to the [UDS+
            Implementation Guide](http://fhir.drajer.com/site/index.html#uds-plus-home-page).
        )

        version VERSION

        validator do
            url ENV.fetch('VALIDATOR_URL', 'http://validator_service:4567')
        end

        PROFILE_VERSION = '0.3.0'
        PROFILE = {
            'SexualOrientation' => 'http://hl7.org/fhir/us/uds-plus/StructureDefinition/uds-plus-sexual-orientation-observation',
            'ImportManifest' => 'http://hl7.org/fhir/us/uds-plus/StructureDefinition/uds-plus-import-manifest',
            'Income' => 'http://hl7.org/fhir/us/uds-plus/StructureDefinition/uds-plus-income-observation',
            'DeIdentifyData' => 'http://hl7.org/fhir/us/uds-plus/StructureDefinition/uds-plus-deidentify-data',
            'Procedure' => 'http://hl7.org/fhir/us/uds-plus/StructureDefinition/uds-plus-procedure',
            'Patient' => 'http://hl7.org/fhir/us/uds-plus/StructureDefinition/de-identified-uds-plus-patient',
            'Encounter' => 'http://hl7.org/fhir/us/uds-plus/StructureDefinition/uds-plus-encounter',
            'Coverage' => 'http://hl7.org/fhir/us/uds-plus/StructureDefinition/uds-plus-coverage',
            'Diagnosis' => 'http://hl7.org/fhir/us/uds-plus/StructureDefinition/uds-plus-diagnosis'
        }

        id :uds_plus

        # Example urls generated here
        patient_ex = File.read(File.join(__dir__, 'examples/patient.ndjson'))
        patient_ex_route_handler = proc { [200, { 'Content-Type' => 'application/ndjson' }, [patient_ex]] }
        route(:get, "/examples/patient", patient_ex_route_handler)

        condition_ex = File.read(File.join(__dir__, 'examples/condition.ndjson'))
        condition_ex_route_handler = proc { [200, { 'Content-Type' => 'application/ndjson' }, [condition_ex]] }
        route(:get, "/examples/condition", condition_ex_route_handler)

        encounter_ex = File.read(File.join(__dir__, 'examples/encounter.ndjson'))
        encounter_ex_route_handler = proc { [200, { 'Content-Type' => 'application/ndjson' }, [encounter_ex]] }
        route(:get, "/examples/encounter", encounter_ex_route_handler)

        group do
            title 'does example work'
            id :uds_plus_trial_group
            test do 
                id :uds_plus_ex_test
                title 'Receive UDS+ patient'
                run do
                    puts ""
                    puts "#{Inferno::Application['base_url']}/custom/uds_plus/examples/patient"
                    puts ""
                    
                    get "#{Inferno::Application['base_url']}/custom/uds_plus/examples/patient"
                    
                    puts ""
                    puts request.response_body.delete("\n")
                    puts ""
                    
                    pass
                end
            end
        end

        group do
            title 'UDS+ Submission Tests'
            id :uds_plus_submitter_group
            description %(
                The included tests function as a rudimentary Data receiver.
                This receiver will retrieve the import sent by the given 
                Health Center Submitter, confirm a secure connection, and
                validate whether the import's contents adhere to the UDS+ 
                configuration.
            )

            #run_as_group

            # Receiver
            test do
                id :uds_plus_receiver_test
                title 'Receive UDS+ Import Manifest'
                description %(
                    Test takes from the user either: the http location of the import manifest 
                    or the raw JSOn of the import manifest itself.
                    It attempts to GET the data stored at the given location if a link is provided,
                    then validates whether a FHIR resource can be generated from the input data.
                )

                input :import_manifest,
                    title: 'Import Manifest',
                    description: %q(
                        User can input the Import manifest as: 
                        a URL link to the location of the manifest (ex: http://www.example.com/import_manifest.json) OR 
                        a JSON string that composes the manifest (ex: {manifest_contents}) 
                    )

                output :manifest
                
                # Manifest Test
                run do
                    # if the input was a url
                    if import_manifest.strip[0] != '{'
                        assert_valid_http_uri(import_manifest, "Import manifest uri location is not a valid http uri.")
                        get import_manifest
                        assert_response_status(200)
                        assert_valid_json(request.response_body, "Data received from request is not a valid JSON")
                        manifest = request.response_body
                    else
                        assert_valid_json(import_manifest, "JSON inputted was not in a valid format")
                        manifest = import_manifest
                    end

                    #earlyStop = 2
                    #while manifest[-1] != '}' && earlyStop >= 0
                    #    manifest = manifest.chop
                    #    earlyStop -= 1
                    #end
                    
                    resource = FHIR::Json.from_json(manifest)
                    assert resource.is_a?(FHIR::Model), "Could not generate a valid resource from the input provided"                    
                    
                    output manifest: manifest
                end
            end

            test do
                id :uds_plus_mvalidate_manifest_test
                title 'Validate UDS+ Import Manifest'
                description %(
                    Test takes the resource generated by the prior test,
                    abd vaklidates whether the resource conforms to the 
                    UDS+ Import Manifest Structure Definition.
                )

                input :manifest
                run do
                    resource = FHIR::Json.from_json(manifest)
                    profile_with_version = "#{PROFILE['ImportManifest']}|#{PROFILE_VERSION}"
                    assert_valid_resource(resource: resource, profile_url: profile_with_version)
                end
            end
                        
            # Validator
            test do
                id :uds_plus_validate_test
                title 'Validate the contents of the import manifest'
                description %(
                    Test iterates through the data that the Import Manifest 
                    links to. It validates wheter data is found at the given points,
                    and that said data adheres to UDS+ guidelines as provided for
                    its claimed data type
                )

                input :manifest
                run do
                    skip_if !manifest.present?, "No valid resource object generated in first test, so this test will be skipped."

                    #resource = submission.resource
                    manifest_hash = JSON.parse(manifest)
                    manifest_content = manifest_hash['parameter']

                    #Iterate through the types provided by the resource (pseudocode for now)
                    #TODO: change list_of_types to whatever the import manifest calls it     
                    manifest_content.each do |source|
                        #Iterate through manifest until udsData is found
                        next if source['name'] != 'udsData'

                        profile_name = "NO NAME"
                        profile_url = "NO URL"
                        source['part'].each do |container|
                            case container['name']
                            when 'type'
                                profile_name = container['valueCode']
                            when 'url'
                                profile_url = container['valueUrl']
                            end
                        end

                        assert profile_name != "NO NAME" && profile_url != "NO URL", %(
                            Input Manifest is not configured such that resource type and url
                            for a given input is conventionally accessible.
                        )

                        valid_profile = PROFILE.keys.include?(profile_name)
                        profile_definition = "NO TYPE"
                        assert valid_profile, %(
                            Manifest defines contents as type #{profile_name},
                            which is not a defined UDS+ Profile type.
                        )

                        invalid_uri_message = "Invalid URL provided for type #{profile_name}"
                        assert_valid_http_uri(profile_url, invalid_uri_message)
                        
                        #TODO: Figure out how to retrieve info from the url
                        get profile_url
                        assert_response_status(200)

                        puts ""
                        puts request.response_body.delete("\n")
                        puts ""

                        #pass

                        puts ""
                        puts request.response_body.delete("\n").gsub(/} *{/, "}SPLIT HERE{")
                        puts ""

                        puts ""
                        puts request.response_body.delete("\n").gsub("}{", "}SPLIT HERE{")
                        puts ""

                        puts ""
                        puts request.response_body.gsub("}{", "}SPLIT HERE{")
                        puts ""

                        #pass

                        #profile_resources = []
                        #request.response_body.delete("\n").gsub(/\} *\{/, "}SPLIT HERE{").split("SPLIT HERE").each do |json_body|
                        request.response_body.each_line do |json_body|
                            puts ""
                            puts "TYPE: #{profile_name}"
                            puts json_body
                            puts ""
                            
                            assert_valid_json(json_body)

                            #earlyStop = 2
                            #while json_body[-1] != '}' && earlyStop >= 0
                            #    json_body = json_body.chop
                            #    earlyStop -= 1
                            #end

                            resource = FHIR::Json.from_json(json_body)
                            profile_with_version = "#{profile_definition}|#{PROFILE_VERSION}"
                            assert_valid_resource(resource: resource, profile_url: profile_with_version)
                        end
                    end
                end
            end
        end
    end
end
