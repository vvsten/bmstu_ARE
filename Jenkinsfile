pipeline {
  agent any

  environment {
    PYTHON = 'python3'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }
    stage('Setup Environment') {
      steps {
        sh '${PYTHON} -m pip install -r requirements.txt'
        sh '${PYTHON} -m pip install -r requirements-dev.txt'
      }
    }
    stage('Compilation Check') {
      steps {
        sh """
          ${PYTHON} -m py_compile server.py
          ${PYTHON} -m py_compile voicegen.py
          ${PYTHON} -m py_compile model_loader.py
        """
      }
    }
    stage('Linting') {
      steps {
        sh 'ruff check .'
      }
    }
    stage('TODO Check') {
      steps {
        sh 'bash ci-check.sh'
      }
    }
    stage('Tests') {
      steps {
        sh 'pytest tests/ -v --tb=short'
      }
    }
  }

  post {
    failure {
      echo 'Build failed. Check the console output for details.'
    }
    success {
      echo 'Build completed successfully.'
    }
  }
}
