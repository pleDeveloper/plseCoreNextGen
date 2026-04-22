const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    modulePathIgnorePatterns: ['<rootDir>/.localdevserver'],
    moduleNameMapper: {
        /* LWC modules — conversation-core package (checked before the catch-all) */
        '^c/pulseConversationHub$':
            '<rootDir>/packages/pulse-conversations-core/force-app/main/default/lwc/pulseConversationHub/pulseConversationHub',
        /* LWC modules — core package (catch-all) */
        '^c/(.+)$':
            '<rootDir>/packages/pulse-core/force-app/main/default/lwc/$1/$1',
        /* Static resource mocks */
        '^@salesforce/resourceUrl/(.+)$':
            '<rootDir>/jest-mocks/resourceUrl.js',
        /* Org info mocks */
        '^@salesforce/org/(.+)$':
            '<rootDir>/jest-mocks/orgInfo.js',
        /* Apex controller mocks */
        '^@salesforce/apex/(.+)$':
            '<rootDir>/jest-mocks/apex.js',
    },
    testMatch: ['**/__tests__/**/*.test.js'],
};
