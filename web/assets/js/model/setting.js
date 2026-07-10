class AllSetting {

    constructor(data) {
        this.webListen = "127.0.0.1";
        this.webDomain = "";
        this.webPort = 2053;
        this.webCertFile = "";
        this.webKeyFile = "";
        this.webBasePath = "/";
        this.sessionMaxAge = 360;
        this.pageSize = 25;
        this.expireDiff = 0;
        this.trafficDiff = 0;
        this.securityAlertsEnable = false;
        this.remarkModel = "-ieo";
        this.datepicker = "gregorian";
        this.twoFactorEnable = false;
        this.twoFactorToken = "";
        this.xrayTemplateConfig = "";
        this.subEnable = false;
        this.subJsonEnable = false;
        this.subTitle = "";
        this.subSupportUrl = "";
        this.subProfileUrl = "";
        this.subAnnounce = "";
        this.subEnableRouting = true;
        this.subRoutingRules = "";
        this.subListen = "127.0.0.1";
        this.subPort = 2096;
        this.subPath = "/sub/";
        this.subJsonPath = "/json/";
        this.subClashEnable = false;
        this.subClashPath = "/clash/";
        this.subDomain = "";
        this.externalTrafficInformEnable = false;
        this.externalTrafficInformURI = "";
        this.restartXrayOnClientDisable = true;
        this.subCertFile = "";
        this.subKeyFile = "";
        this.subUpdates = 12;
        this.subEncrypt = true;
        this.subShowInfo = true;
        this.subURI = "";
        this.subJsonURI = "";
        this.subClashURI = "";
        this.subJsonFragment = "";
        this.subJsonNoises = "";
        this.subJsonMux = "";
        this.subJsonRules = "";

        this.timeLocation = "Local";

        if (data == null) {
            return
        }
        ObjectUtil.cloneProps(this, data);
    }

    equals(other) {
        return ObjectUtil.equals(this, other);
    }
}
