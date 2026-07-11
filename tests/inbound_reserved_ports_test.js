const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const modalPath = 'web/html/modals/inbound_modal.html';
const pagePath = 'web/html/inbounds.html';
const modalHTML = fs.readFileSync(modalPath, 'utf8');
const pageHTML = fs.readFileSync(pagePath, 'utf8');
const scriptMatch = modalHTML.match(/<script[^>]*>([\s\S]*?)<\/script>/i);

assert(scriptMatch, `no script block found in ${modalPath}`);

const sandbox = {
    app: { reservedInboundPorts: [2053, 2096] },
    console,
    DBInbound: class DBInbound {},
    Inbound: class Inbound {
        constructor(port) {
            this.port = port;
            this.settings = { vlesses: [{}] };
            this.stream = {
                network: 'tcp',
                security: 'none',
                reality: { settings: {} },
                ws: {},
                tls: { certs: [{}] },
            };
        }
    },
    localStorage: { getItem: () => null },
    ObjectUtil: {},
    Protocols: { VLESS: 'vless', MIXED: 'mixed' },
    RandomUtil: { randomInteger: min => min },
    RealityStreamSettings: class RealityStreamSettings {},
    StreamSettings: class StreamSettings {},
    TLS_FLOW_CONTROL: { VISION: 'xtls-rprx-vision' },
    Vue: function Vue(options) { return options; },
    window: {},
};

const modalScript = scriptMatch[1].replace(/\{\{[\s\S]*?\}\}/g, 'translated');
vm.runInNewContext(
    `${modalScript}\nglobalThis.__inboundMethods = inboundModalVueInstance.methods;`,
    sandbox,
    { filename: modalPath },
);

const methods = sandbox.__inboundMethods;
const controller = { ...methods };

assert.deepStrictEqual(
    [...controller.availableInboundPorts([443, 2053, 2096])],
    [443],
    'reserved panel/subscription ports were not filtered',
);
assert.strictEqual(
    controller.preferredAvailableInboundPort([2053, 443, 2096]),
    443,
    'the preferred port did not skip a reserved service port',
);
assert.strictEqual(
    controller.chooseAvailableInboundPort([2096, 8443, 2053]),
    8443,
    'random port selection did not use the filtered candidate list',
);

assert(
    pageHTML.includes('Number(settings.webPort)') && pageHTML.includes('Number(settings.subPort)'),
    'the inbounds page does not load current panel/subscription ports',
);

console.log('inbound reserved-port tests passed');
