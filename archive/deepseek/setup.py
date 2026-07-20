from setuptools import setup, find_packages

setup(
    name="deepseek",
    version="0.1.0",
    description="A Python project for deep learning and search",
    packages=find_packages(where="src"),
    package_dir={"": "src"},
    python_requires=">=3.8",
)
