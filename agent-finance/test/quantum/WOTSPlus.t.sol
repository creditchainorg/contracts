// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { WOTSPlus } from "../../src/quantum/WOTSPlus.sol";

/// @notice Cross-implementation tests for the post-quantum signature verifier.
///
/// The vectors below were produced by `reference/wotsplus.py`, written from
/// RFC 8391 independently of WOTSPlus.sol. Testing the Solidity verifier only
/// against a Solidity signer would prove the two agree with each other, not that
/// either implements WOTS+ — so the signatures here are the Python signer's
/// output, byte for byte, and the Solidity verifier must accept them cold.
///
/// Regenerate with:  python3 reference/wotsplus.py
contract WOTSPlusTest is Test {
    // vector-1
    bytes32 constant PUBSEED0 = 0x9637c67521718c9d9429610b39e8e090102e5083ecc7c0740a2c77ebcf700198;
    bytes32 constant DIGEST0  = 0x06c51ad0709558483de3134e95eb852c653e375b373465165b36166d076c0b6f;
    bytes32 constant PKHASH0  = 0x459c40cc291bc3e54d55b5741c605b583ec048824c9ae7df29b33bb46886bfdd;
    // vector-2
    bytes32 constant PUBSEED1 = 0x356e40ff2a3b4bb97a46b4f7aa2efd820bcd0a7599c2862c8a8a9435f3b74f69;
    bytes32 constant DIGEST1  = 0x53b785cd41139c75d992a4a927e8b7369795866f38597e53fcd6967514560e6e;
    bytes32 constant PKHASH1  = 0xb74ead528b5071247dc79ad236c0f1f743510a946abf123d893fa086d4766b5e;
    // vector-3
    bytes32 constant PUBSEED2 = 0x174f8a639a308be64daefa357978e40c31e1606a116abbab41f5d8bfcf9afece;
    bytes32 constant DIGEST2  = 0x2a73404b3349e767b4fcbe19ee998f2962350ddc96a0aedf96133da3ff025eb8;
    bytes32 constant PKHASH2  = 0x1b0b7862623fb9c46312969a4e5f2cb31e3dc3a2fd56b89e0e80fe81133a6a13;

    function sig0() internal pure returns (bytes memory) { return hex"12e881039ea88496721bf8b688c26a7c53988b4a0cb85b0e10f3d2c51c2b5657fa94d5751b594d9b0a8c59362479e9b83810143f592bae6896e45965157517512f387633ba95074d2f1f3a069d339c15a2f1ec03bf1c2d30b3e44221e076573b9b2f7ae5afd4f301f9bd288152eea4b3d6622d4190530c3b893932b90a03933c09e9e24b5e542f0226335e4e8c5c9d4ff3ab2cd163126933124db27690419ae77edc03ed1ce9c786ff811c8a572703ad7d26c1cd770f4755e93e6d00870d621e7fa1af42f62c0f7ba0e8c3f1e958df0e90b78e917f2660d44a28a4a649bcfd2d6c0f18b63b64a6dc937a0ca5e9d001a295ac98a3e6ba5dcd20449aef8d15a48d92d4936d3dd331b235f2bacc9f4f1497703192f0ca2855a26688e32026d4d5fead0f23dfe968e600504a13747aee4cf1e3db0545be33996f49fe8112bc27493e4a969faf8296b9ce2a95faf42644d42c5525706683ab9d223ed202caddec2721ebde8664925d97ea20f3bee999eeadb3b72dadd98ac81eb4ca276c1f99b949fa2199622b2f6219ad47a6212b83a4ccf821369f7ec2d842b9ea8576544667555cd32c2a4c45fce7b52b98279f9bdcbd28ae8ac09f261040d3d7f0f35e5ec7c2dec27f093d02c974e548aac0bd53617a05c436afa6b07e57a1c4298ed3f5ec5da17545a4677862a6779eaa0727577eecf60c6883821f8470aac177c353a59dd323c620fa42a42d6d0e5099215abc8f1ee24bf8deab8c87ab98d4a3cfb47904d8bc06a7f0ba075b812665375308e4c19c24202c6d47e6cdbbfd08bcd3e60ade0307bad0abff506fb780ad3cf546fa1e93fcf4acbbdeb3a05e9b4f4e460644f3568131677f33347e70ce2698b60e5e24c09d3976ed52ebf74773a5001808dd4f6563a57adece0ff762ddc62cee67c88d5255d9a76f560400e2466f07a6942294e57a9a405a5ddbaf0ce5234970f928cd93c19d284a9fb92fcda8d1b7781758266d8843f098ac4dee5a02a3aed8cb9796152545033fc91f4d434daf4a8df451ef8d75fafada3f010dd62a47db959491000a8aea33ae3865cf9360d58467058f914dfe9c7c483d5bcdf64367d25f042d15aa761b5685f6a1767c9cd5e3c8a454e648de818786bd556ea393d8600561a752d35823a9c92ebcf6265ff2974b2fd271b9708870d9f2e793f5366d234f7aea675d64bd18bed5d5371ea50a470811295eef7621da67fc9ba2eaa097f06666b3fc24e18f6487deec70c8d1c12ccf6516b40efe200aa326e36dc053619f35290f81074e5a29ffe700866f98b7f6473aa65df4bc170bcd55e56c709cebdda6c1591d66b64823d0902cd924252975c091c2d157d77a70f8089f353e90b0ecdc000df3ca285c6c1ec8106cd73deb736ca6297bf329696db651a80c8b73f133754ff419b2752e715834de21c09904ebef84a601a5c03ca328254ffd2ebdfbdcac966c98ecbfb304b4d21fcdd178e1b4d29f95ca4dbb62aeb787e5c2313308c0a2a72fa88fe130d20e8d12dad16c11bd2ce581f28a7721d332ee6672dec255a545f507586bee007693a3e2d56057dd0b91962c468b71c3672e8768888d833fef569e47c51f0f507408f1561faf0b72aaeea5611e9fe9a0d82869eb8dbc51dfc698c200df810196d154e281dea10ff7395b0eb21d7c2d7dfc3b054f50a2cc4349c4153ddeab5bde545d8ddb1fa4b38bda490b3d45045e6f1c08b4873852424c597ef4b6d333a9f43692a20fbb53a8b41f471eb26aade9b04f800f2d096603322df0d41e697f768270a563defebe60dfa0f48e3bf7976b1779077500ea0300106e6572707c6659807e057d6d074246d5c49eea89cf508a8ed74363be7b16b7b73279dd0b37f5e3bbfbdf23a5db4270697a50872961de673fa62b276112d43a60037533ba70e3f2a1a9757b9f40f40d54a71bc336ec787fb84cdace57eb12008e81444ab5e731c04631fd764e894c590714ac8335b14361f91d1a2f60196f19bb792b4128abae588873e74b1f396d1a88ce4e195fdeaf241c3f517e70f133e4435af56279300490b00a6a1c1e0077aec886d2c574271248b34f1f8d8cc025414fb9801ff7b03bb1dd5588c357f85cb47ce49c8631552db64e68411d29960e53ad8fef79a039f240baa4f4839bc2734a9ceb696e62ce4de5d1623211fc48d998233a9cc521c88b2632eb88e325f7f7409c2821042c481e8773bebf50959ed2f848011c416750c413a3b9b29d2c8d6880a8c4eba9ba23d541656e802932b9dfd181063760f9995d50848080552fd94963160281e6ef854b046a0abb9c61438c0068d066395fb69644c3d825369c3fa450e1b5f6c36dd84bc2b52458282b2724f736a39c45d1be6a9e1befaf14c07d09a689239bfaf8118aa136a72509fdaa223d4dd9a1530ac7bdc64853cafa4a7de5bd844e1084eabe7661dbafc947bf2f555c794330bd8eb745e6b6c1d9b5e6d66930ed5e8ee53fa124dbc5bd26791aa34a371e1c45ea1b1fec2447f8621901c8f359b7bc94195bc198b4e58fe3cef2621bbb4c071de8305c0fa0725dd047ae184efeb45354277f3cf30960f86873d0484fb91278d3d06f137c83c7ff7d701608e928e5dfcadf85cb2b861df4b2e6a856e2adf58bca4cedd549dcaaf177647b907714c801f41e98bf201d4648c07d79fe388d86b580f3f305d23d7129e2107b46568f616bcb52e4893f76f7033c15834212e818ba1e7c878cd0a04a7932640992b648bf26196bf2665edc7ee733dc7cee1e146208bda9b9e82c277d83a4dc746b079e6cccadfd32c53276c3111c90c51b06335309e36e384618866e1b32b51f192a0411fb58a1afc311f6568e4156b8a0c6d2377014e081c6bf05d189d2c74fce81141eebd80efb53ef3bcbd31b0ced744bda35032ce972aabd63ba2534158cd0e56e7efd144826c1160d48b79230519437bd853bf4e32eff9d26839558daac736a7ae7b49f2714c75b446428e0c18c45b099d067486d20f3952e6af7339bb77ac444c8d926aa48322a49"; }
    function sig1() internal pure returns (bytes memory) { return hex"64df2c5736ee045f131bdd56c91a439758d231cb3c6ada6632bc032e789a0e1280af687b9f084afb725a4e6ba92a3180ede76f440ac68cab7bfdaafa23069e0f9ab32b2ef8f3fd8dade3269dd3e9d3c8939eac83b4803dffbb2b8c73810e5cd7b715219b22ffeb92086dbf7cf08ff6d81c7c065cd9ed0b414fc29409d984fb0bc4c4a154697e5d5836a2329d99cf4d5ec10ee04f0e39a29518fa47cbabce2b553718e8db465adb750323ec27a45adcca45a8d2acc6d8fa5f315a0a71e80b8e3e735571c2ae9376329b211fa3cc588ea68fdb5f99d9fdcdd9dab13973dc2c4d5b6505617f3fe97351a08f9ce93096c6a09ab6dd00222be1555658f669316b6eea1d5bc1efb9c4b6047b6d63cb8f5a87ea8f5badca4540ee5ef8ad8a0ed51fb4630cfa9c9e387ff667bdadd9cec85485d2c7ef4a96641a3e7d6a137cc996a8649009ae93bad5dceee4048a39bf4215aa6abba5de7a9ecf7274ddf7b29d66b614aca48be71e87be1a6089290ed2244139e5aefd89b9827627d01995e9ec12fadf744b9f68df2f227406bccff7b23036eb598337f920c4188c99d34734a3a5a7d66ef970beae8ebc611e995acfde09920f28a4bfc3cec285632db8d8189756c941820ab6b0eb37a074d4f353b464181ce5e27246947e77550d0446bfd8287f4c493ca1f1eb72d7dce777ab3266aab2251be0f71c663f18160df8d43f710656b1362e1cf0440e907eae4bf1c102d2ff12dea676af74a429ecb3c6491425a1be87ec01b614ef03f66834b2dfa8d33bdd8d31608eaa6034463b12554b1902ed11952b79c032ac50f3123545d81c33291390debcc433f0e5e3eb0c0263d6ac9bd0050f6c968e8366f8b8ee1337bf7b572040512c3dfa718be9ac7e4a2b4226bade5a8a0272ee5f75b1dba13cd1634c6262c268ab9a7ca313f09b4adfee6feb6fd0750afec2e7597f26c4cf5e5d0fa0196398f259f211b827cdb42afebbb1497ca136d30cd09c27b9e5e5f472cba8d137a7bf37f637d0f27f9c59584f61bc7a62cf4487953ba3f835ce4ba66d679f91149fbd835e0f18f6a9ee251f8e6a01f9b7b5950789c71f03f6eb52cdcf04042130053b8b87085b4c31ed1ba6042f94ecedca8a87b1ed578209cf1296cd215de7628ac572ee8611d1b67401a058aa687c6639c4cb0193a9acd9d0bffb21f03643f62093e1fb7de531364a3fa9de35a24a447742ac1dae9e43ab7d28c5b74804ac1f6ddaebbd09f88e894559b2bd163424c351eb0993cce0c593dcb0340477e69d112a82b28172b83856af0be1aac3f576066ef86e24680ca7390d4aee3c7dca670b2ae650b8dafa8f8c1d89799f48f8433c1e1c9a391bda9a5d04a70e5aa78105371769111aba2aa6725b65d3400489a6494c65c75b7392c28320f4fa06e417b4c02e0e0faaa4713e090fa1979465f10d087885d53b61aa3c92dafd3f325b7e8361418c02b5918fbeeed42acf40159721809eae27cc6df717b34daecf4ce7f0cc06db86b6101cadfac41441b1e554046c49deb74220af30fdb4737bef32167eb17d575882bd857e5f182b74c465f97a30944fde774f6da366c2f415d12f3b3089b6e25d152c024c121044f78f40adeb6795e15743c5b4d11ae37ee8f7a8226fad4e10361cae58d74eefce030473dada26926977a8a65d2735cb2132d953a6ea6dea28bd27be77d842d6cb1037042aed773dffd7143c956a1802286017c5323f700a8dbf60cdf46be27317e871b35b8c85a6ac07139dc8341bc68bb021a56ed093646f6538e7980887b9cd4ff0c19a290483ea0f04619f35f93767d62b661d736482ac78f898d78df16fe3a46e41ca177e3744e86007830fd3e9c9849b6f59d9ff33eb11c12dfd15f0abc1a195d8228b4ea4b21c01d35ee7d8a3332d7a22b5a0da8a87a8083e23ea1c44082a25f94e4519e74ceee6efe2892ac43f65a0d8a6ddc7213601b98bc958fa55fb6236d800c36a3f6c97fcaa95a472aaada3f623efceaaebc7584650062fec3f758330458e6d229ecb9b46d60519672c8e207d3ffd662281a81d6eb6f908cc2287c2e67a8688772af8ce60dd9ad3ee37d920b8eaf1f3e7b7f7082ab04a7f2a38793e5e4dec3e31fb563bd8d8a3fda1272b2302bb8b0d4efdc5aed2160ec159e1f8a70e06df976b8b134c5c77f1644871ead0cfb3de102d5985dadc8ff77113e57cbd27142e8bf792ff981fc660681ccb81286a5ce4cfb4ba625a33d07123bc74478c0159130f03a1e876fc2fef09bfb307917624cee59255e89940c5d68d839efadfeaf55ef372b93b4720fcdd44f5c9c8beb1d8f67fe9f61aade599900f590c0aa0351013f8357bb92855323092019a21bb681da43033854a021655b4e622786aa7624dd4cda00b7da0414c2a5630701138b361eac817ae14ad262d519fc4d89a75d5d9094e80f18b9cfe81a959f31acf932be2107d09edb724e2b30027809345ba0fe12950ef2a2970d67b25f1d0ae7bdf824995f83c10b81cd729075946e17e26cf71ab793a7dfc18abfe974cfbf3f0ecb3ec350ba984a92ef594c88be50bf633b00e62d79137c7cf695bd134e0a6b6bfc041d44a2a791303946709a7555021634e96dcd5e94a9629f2af36d90816265977fddab506b676fe55cb6ff4edd6d5c6facd8b030c40f08453b1eadab552312ae5f5fc3ea342b08406d44ff29fb23945cbe6d027a3d52a9994d9b46763478138f1596427be64187b46f09d57fc4545ac6c294b3af4d5a1bbe06f1c2f95f2805f740aa85e55f2c3188fe462c23002a8ca55c23169aec35c7bc622e617316a96b83b37d5291ff2409cd61d3f0125c6a8de526091a1e28a3898ef94a6e7b00e5cb919c1f23f6bb8b8c5ddffa47ee317060529361d384f2acd2b91d30337ab24db1a5395e7e5772e4f80149a20ce4825d69ef297c1704025e38b17339eea5bfbc0a8113ae5bc3bd4c031ea147087f679fda4c2d26a6fad7b90a15f1cd6f2fdcac87cc11e1b05f4f27987d48ecad174f4f7ceb7cc553ddb9f76dbc502"; }
    function sig2() internal pure returns (bytes memory) { return hex"6ddbd3340829bb273e8a4eb4320078a4aa99d32908691b3d78b2aba2e79152df1d643b8b403aacc1d405967e94c1f188b274b8fb32984fb431bb10729535ae1e1a30e305db4150c5383bf3c1462caddbe7e844f4e3dfa8739297038ba2694fff7e9c6d6a7c433338282ad894bde39ded05ff019d63ade86358591580d9aa0ed80d7c7166007653f6e49bcb5e1c02ebc32f1bf8aa92ee0a71c358fe74900e4cd2af52f32ac8a3f7f4c61b9ade70f10b8b46002cd690303756ae26e9cf4b19fc48f2504f23c216db5de7b214e656ba0c1e1f172031b35e2dd884f86fad264d0771ec427b4f42ae1625eb57ddb42d2aa3e3c5b32cdc026302e83b5906e5595cd7f0d0f23beed902f7d7272baf1ac406846eac50c9ed1e7ebdbb51d496d818f7f933d8627d817f7fd5fa629095c225c2bdf23a3e32e3a40145bb0c6ae82049024d48282f0c04880304278b2b0813558a2110e48c6fe3b6749f06e0d224eff6cd1b95eb0c05889255e7039c4aabc02f6cc30a8f8ac661fde4de7aaf19ed54ff7fdbfa30f5eb0e65d46af89ccca0ec095823b7d09f63bb5032512d4efdedc12312148323e0b2bd6641997a06224cbc97abd1709fa546a98a32d1df8b320fb88cad2c70a2942fe96624fd1285168e4599412f1e78ee1dcae4f12bd9800b67f182953719a9d73f126bac0a43fcd780ba0c06f39a8eebe2d473fc36f70c1bbd4460495223ccb83ba382c599c7cc5c31700e0123eb4819fe3e3121b2d2099cfe57ae5c94c20508a5c55fe0985a75d6d904520051391c160a47244d95064ac410a6db4aa570962843a2f9a52aa288ee5f59c63b2a95250a4165903b142f426bf6921654b3ec19dbc06fb6e3c7520cd48f8ab49e426a48b62104ef73bff8ddb8b2066166cfac5c37049767f341aabd5a17ca4a98c439aba58e175fc27968f3f73b5d0542d8424122e2a018470ab674e6d6816739eda3dbdc4f5e12589d12e9e07f7970985ff042ee0033e3e837a7f71a0de7b8e96037bb74a910ace8b795c9118a850a8b97e43f3c4a6bf3fe393544d8114712945750a927534d19ce6d76084ed7fb41a8c9f774d7b129ed4247666314ad006a403db35381767823c3fa7d540f5275ef921b4cf977709d01d35cb10e1ae584aeaf5674b0b9a3a1be65dddddf0146a24cb869c131a3b40c8329c26257cb173e16df12c71e627cd7065623e9ff6a2cc2e1b5b9fd34a14562b832a0fa721c46d400e7c090dc2bc409ae7e4810f6386d86859b62d7256e9b2003b9e18ec9a45c3fcdc18693b6a1aac56938897f19b861312bb343ecfe04ba79b6c79ecd1246747ecee04cf6f05cb4a0d2397c0dc435db7ed95250ed4a1d9c09272fea604360a954737abc32b6776def16913eb1f111a5d0d9416e0433611961685cde2ec1738bfa9e2057d397708e49a6c5195eeba1b205886fe34cf79ca06664def07c69fb0eb1cfa2714d335116265a7c2a55e4d468d6b5b6846846be17035f21d0f62d642b47e242acd27f31e65bd67ab57115369fe1b045c123944d228cccb6a4d859311cf69895169cf43b6bcaaceb15c990e497f3867ee5bd2e8c2f4950c37f44eeb2e5625649db346a27531043fef942c27fa5aaf83733ecdb0786d603de6cf6475c455bd7ffa83e31fae1c34aaf61ed5d92c5b8406f0dc4a26a945e0c409dde51f09eead074159e18a2c53d2caa0c550cccd6f7987108c7c48bfa5a3e2ad76679c8cf5efa9c4cf7e2a924890a74943a2ebdc379b0cdc3c6931ee31b7b5d355c98891bcae5b813b4451837036d115f7b2a993f716044d4cd1a6f7f731d4f921d840bae9a8bbf21d84d69dd5c71cea88a790b95ce5e695e8cbfd8507e04a64abedcc8616de926e3e39d1e9ad6efb26aeccdcf17bbe5c9cdf46c85de446d77c533e1c2cf0b6b67b869635b40922b3a96f34f1fea692ae3f00f28f0838df3c759cdb2365ce79c7ef3cdacf3d873fbaf0da22014175e40e157a8eafba4285a93a70c364362db6079006dc7a2b7cd5594fc3552329735b79984c89284220fde21c53ea5553c0b4008308eada531b77e25e9ad21e4b364e3c10388ad9bc5a0cc53f2b4e271b8b54779893d8edc89940a0d7ec153360b3467cc63dce66aa12edba4efd5605b5eeebf78aae7bb2e8ad295caae9be73d7ede8f107853d77feb9e73c7959a5157b119775227ce55e70437b6e49c6aa9cf890a9ca5bae49af92ef1cec85f816c6eeae2eee9afa6f2f926b5614e5b7f081aaaa45153aab74e65b5af9cb17686cebc35c3c06d52544a54f8ece8e005e82e05eb81179b19c7b0569bf184f1b5ed3baf115a7ddcc06edd1440c34dd56c001471d8d8f36715249405d0b4c757bda253b83457d345d01a88e1cd4ebc8d462a3db5f5eff626e2c12d29f7119729256c6b43c1813e69b922f4a99c447b01dbea020c96117af78299b4a23860a85a91ba8c051a6fa096f553a8d3edc024f82ac84f4463e1e3f23f52977c879474a2827d6b5bef64782380168330f4031fc57c46b864ac59b2ae0f74ffdc710478ae18cfa6354f13f627f563b43f0727ff60be03ade780e46a0599a18dc71193eae7a9bcc22810c825291232a5e29b7d5f58da72bf5e23342b406e83c380166cf67c83d87b0810f263c18f983a2e26bfe2d0e6a932bb12ffef7aff109961685df334530c5250c4d8facac4632b60fafa28180cf4948298396c802f35fd32cc3a94a80129f6925b4451a9f5ed35832db95b51bda19fa4de1bbfc08f14c8a43fda573aaf23c45cb22a4dfc1478d4a13d634a82581bc7281dc07aaeb3af775e06e2b776620566043409c6a1bb40d6703ab519c82623cfc4e4071fe425808cbb91afb2a6292949f9a49d1a7f5b4f784f3c88ba16fc99c6734b3240b902855648e4356823197ec4896ebb3ef009b84ceb3eb27a870e0e4b61df372aa0c5552688031610b4363687fd8796e41b2b3f97605a1d9d8d0f1c56dafafbba5faf6c77790cd0955437afe0a005abc12a8e9ac622fa0d3e9ebc9807250071fdacd14b"; }

    // ── cross-implementation agreement ───────────────────────────────────────

    function test_verifies_python_reference_vector_0() public pure {
        assertTrue(WOTSPlus.verify(DIGEST0, sig0(), PUBSEED0, PKHASH0));
    }

    function test_verifies_python_reference_vector_1() public pure {
        assertTrue(WOTSPlus.verify(DIGEST1, sig1(), PUBSEED1, PKHASH1));
    }

    function test_verifies_python_reference_vector_2() public pure {
        assertTrue(WOTSPlus.verify(DIGEST2, sig2(), PUBSEED2, PKHASH2));
    }

    // ── forgery resistance ───────────────────────────────────────────────────

    /// A signature is bound to its digest; any other message must fail.
    function test_rejects_wrong_digest() public pure {
        assertFalse(WOTSPlus.verify(DIGEST1, sig0(), PUBSEED0, PKHASH0));
    }

    /// The public seed is committed to inside pkHash, so a swapped seed fails.
    function test_rejects_wrong_pubseed() public pure {
        assertFalse(WOTSPlus.verify(DIGEST0, sig0(), PUBSEED1, PKHASH0));
    }

    /// A valid signature must not verify against a different key.
    function test_rejects_wrong_key() public pure {
        assertFalse(WOTSPlus.verify(DIGEST0, sig0(), PUBSEED0, PKHASH1));
    }

    /// Flipping any single bit anywhere in the 2144-byte signature must break it.
    function testFuzz_rejects_bitflip(uint16 bitIndex) public pure {
        bitIndex = uint16(bound(bitIndex, 0, uint16(WOTSPlus.SIG_BYTES) * 8 - 1));
        bytes memory s = sig0();
        s[bitIndex / 8] ^= bytes1(uint8(1 << (bitIndex % 8)));
        assertFalse(WOTSPlus.verify(DIGEST0, s, PUBSEED0, PKHASH0));
    }

    /// The forger's advantage in a chain-based scheme is that chains run FORWARD:
    /// given a signature they can always advance a chain, raising that digit.
    /// The checksum digits are the complement of the message digits, so raising a
    /// message digit lowers the checksum — forcing a chain BACKWARD, which is a
    /// hash preimage. This test performs exactly that attack and requires it to fail.
    function test_rejects_forward_chain_forgery() public pure {
        bytes memory s = sig0();
        // Advance chain 0 by one step, exactly as an attacker holding sig0 could.
        bytes32 elem;
        assembly { elem := mload(add(s, 0x20)) }
        uint8 d0 = uint8((uint256(DIGEST0) >> 252) & 0x0f);
        if (d0 >= WOTSPlus.W - 1) return; // chain already at its end; nothing to advance
        bytes32 advanced = WOTSPlus.chain(elem, d0, d0 + 1, PUBSEED0, 0);
        assembly { mstore(add(s, 0x20), advanced) }

        // The advanced signature corresponds to a digest whose first digit is d0+1.
        // Without also moving a checksum chain backward, no digest verifies.
        bytes32 forgedDigest = bytes32((uint256(DIGEST0) & ~(uint256(0x0f) << 252))
            | (uint256(d0 + 1) << 252));
        assertFalse(WOTSPlus.verify(forgedDigest, s, PUBSEED0, PKHASH0));
    }

    // ── input validation ─────────────────────────────────────────────────────

    function test_reverts_on_short_signature() public {
        bytes memory s = new bytes(WOTSPlus.SIG_BYTES - 1);
        vm.expectRevert(
            abi.encodeWithSelector(WOTSPlus.BadSignatureLength.selector, WOTSPlus.SIG_BYTES - 1, WOTSPlus.SIG_BYTES)
        );
        this.callVerify(DIGEST0, s, PUBSEED0, PKHASH0);
    }

    function callVerify(bytes32 d, bytes memory s, bytes32 ps, bytes32 pk) external pure returns (bool) {
        return WOTSPlus.verify(d, s, ps, pk);
    }

    // ── digit expansion matches the spec ─────────────────────────────────────

    /// Checksum is sum(w-1 - d_i) over the message digits, split into 3 base-16
    /// digits. Verified here against a digest of all-zero nibbles, where the
    /// checksum takes its maximum value 64*15 = 960 = 0x3C0.
    function test_checksum_maximum() public pure {
        uint8[67] memory digits = WOTSPlus.toDigits(bytes32(0));
        assertEq(digits[64], 0x3, "csum high nibble");
        assertEq(digits[65], 0xC, "csum mid nibble");
        assertEq(digits[66], 0x0, "csum low nibble");
    }

    /// All-ones nibbles -> every digit is w-1, so the checksum is exactly 0.
    function test_checksum_minimum() public pure {
        uint8[67] memory digits = WOTSPlus.toDigits(bytes32(type(uint256).max));
        assertEq(digits[0], 0xF);
        assertEq(digits[63], 0xF);
        assertEq(digits[64], 0);
        assertEq(digits[65], 0);
        assertEq(digits[66], 0);
    }

    /// Digits are big-endian nibbles: digit 0 is the HIGH nibble of byte 0.
    function test_digit_order_is_big_endian_nibbles() public pure {
        uint8[67] memory digits = WOTSPlus.toDigits(bytes32(uint256(0xAB) << 248));
        assertEq(digits[0], 0xA);
        assertEq(digits[1], 0xB);
        assertEq(digits[2], 0x0);
    }

    // ── cost ─────────────────────────────────────────────────────────────────

    /// Gas is the whole question of whether this is usable on-chain, so measure
    /// it rather than assert a guess. Printed for the record in QUANTUM-RESISTANCE.md.
    function test_measure_verification_gas() public view {
        uint256 before = gasleft();
        bool ok = WOTSPlus.verify(DIGEST0, sig0(), PUBSEED0, PKHASH0);
        uint256 used = before - gasleft();
        assertTrue(ok);
        console.log("WOTS+ verification gas:", used);
    }
}
