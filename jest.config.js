const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    modulePathIgnorePatterns: ['<rootDir>/.localdevserver'],
    moduleNameMapper: {
        /* LWC modules across all package directories */
        '^c/(.+)$':
            '<rootDir>/packages/pulse-core/force-app/main/default/lwc/$1/$1',
        /* Static resource mocks */
        '^@salesforce/resourceUrl/(.+)$':
            '<rootDir>/jest-mocks/resourceUrl.js',
        /* Org info mocks */
        '^@salesforce/org/(.+)$':
            '<rootDir>/jest-mocks/orgInfo.js',
    },
    testMatch: ['**/__tests__/**/*.test.js'],
};
