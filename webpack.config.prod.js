const webpack = require('webpack')
const merge = require('webpack-merge')

const base = require('./webpack.config')

module.exports = merge(base, {
  // Enable a full source map.
  devtool: 'source-map',

  plugins: [
    // Use UglifyJS to minimise output
    new webpack.optimize.UglifyJsPlugin({
      // Enable compression (options here are UglifyJS options)
      compress: {
        drop_console: true, // Remove console logs
        warnings: false // Silence Uglify warnings
      },
      output: {
        comments: false // Remove comments
      },
      // Prevent source map files from being stripped out of bundle
      sourceMap: true
    })
  ]
})
