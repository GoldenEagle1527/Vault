import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';

class BedrockAwsSigV4Signer {
  BedrockAwsSigV4Signer({
    required String accessKeyId,
    required String secretAccessKey,
    String? sessionToken,
  }) : _signer = AWSSigV4Signer(
         credentialsProvider: AWSCredentialsProvider(
           AWSCredentials(accessKeyId, secretAccessKey, sessionToken),
         ),
       );

  final AWSSigV4Signer _signer;

  Future<AWSSignedRequest> sign(
    AWSBaseHttpRequest request, {
    required String region,
  }) => _signer.sign(
    request,
    credentialScope: AWSCredentialScope(
      region: region,
      service: const AWSService('bedrock'),
    ),
  );
}
